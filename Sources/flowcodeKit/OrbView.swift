//
//  OrbView.swift
//  flowcode — Phase 2 "Jarvis/Siri" audio-reactive orb HUD.
//
//  The centerpiece: ONE luminous orb that morphs across voice states. Rendered with a
//  CAMetalLayer-backed NSView whose fragment shader paints a premium SDF sphere with a
//  soft additive glow on a TRANSPARENT background (so only the orb shows over the clear
//  HUD panel). State is encoded primarily through MOTION and SHAPE, color secondarily.
//
//  BUILD CONSTRAINT: the dev/build environment ships ONLY the Command Line Tools, so the
//  offline Metal compiler (metal/metallib) is ABSENT. The shader is therefore authored as
//  a Swift String and compiled AT RUNTIME via `MTLDevice.makeLibrary(source:options:)`.
//  We never reference a `.metal` file, a SwiftUI `Shader`, or `.colorEffect/.layerEffect`.
//
//  All rendering touches Metal/CAMetalLayer/AppKit on the main thread, so the view is
//  @MainActor. The display link (NSView.displayLink, macOS 14+) fires on the main thread.
//

import AppKit
import Foundation
import Metal
import QuartzCore
import simd

// MARK: - OrbUniforms (Swift side)

/// GPU uniform block, packed as three `float4`s so the Swift and MSL byte layouts match
/// trivially with no alignment pitfalls. The `OrbUniforms` MSL struct in `shaderSource`
/// mirrors this exactly (`float4 p0; float4 p1; float4 p2;`).
///
/// Channel layout:
///   p0 = (time, amplitude, intensity, motion)
///   p1 = (resWidthPx, resHeightPx, stateBlend, pad=0)
///   p2 = (colorR, colorG, colorB, pad=0)
public struct OrbUniforms {
    /// (time, amplitude, intensity, motion)
    public var p0: SIMD4<Float>
    /// (resWidthPx, resHeightPx, stateBlend, pad)
    public var p1: SIMD4<Float>
    /// (colorR, colorG, colorB, pad)
    public var p2: SIMD4<Float>

    public init(p0: SIMD4<Float>, p1: SIMD4<Float>, p2: SIMD4<Float>) {
        self.p0 = p0
        self.p1 = p1
        self.p2 = p2
    }

    /// Ergonomic initializer mirroring the logical channels.
    public init(
        time: Float,
        amplitude: Float,
        intensity: Float,
        motion: Float,
        resWidthPx: Float,
        resHeightPx: Float,
        stateBlend: Float,
        color: SIMD3<Float>
    ) {
        self.p0 = SIMD4<Float>(time, amplitude, intensity, motion)
        self.p1 = SIMD4<Float>(resWidthPx, resHeightPx, stateBlend, 0)
        self.p2 = SIMD4<Float>(color.x, color.y, color.z, 0)
    }

    /// A calm default used when no `frameProvider` is installed yet.
    public static func makeDefault(time: Float, resWidthPx: Float, resHeightPx: Float) -> OrbUniforms {
        OrbUniforms(
            time: time,
            amplitude: 0,
            intensity: 0.6,
            motion: 0,                       // idle
            resWidthPx: resWidthPx,
            resHeightPx: resHeightPx,
            stateBlend: 0,
            color: SIMD3<Float>(0.30, 0.72, 0.95)  // cool cyan accent
        )
    }
}

// MARK: - OrbMetalView

/// A `CAMetalLayer`-backed `NSView` that renders the orb each display tick.
///
/// Pipeline is built lazily and tolerantly: if there is no Metal device, or the runtime
/// shader compile fails, the view logs and silently no-ops rather than crashing — the HUD
/// simply shows nothing. The static `makePipeline(device:)` helper lets headless tests
/// verify the shader compiles without needing a window or display link.
@MainActor
public final class OrbMetalView: NSView {

    // MARK: Shared shader contract

    public static let vertexFunctionName = "orbVertex"
    public static let fragmentFunctionName = "orbFragment"

    /// The Metal Shading Language source, compiled at runtime via `makeLibrary(source:)`.
    ///
    /// - `orbVertex` emits a full-screen triangle from `vertex_id` alone (no vertex buffer),
    ///   passing through clip-space position and UVs spanning the viewport.
    /// - `orbFragment` reads `constant OrbUniforms& [[buffer(0)]]` and paints a premium SDF
    ///   sphere with soft additive glow on a transparent background. The orb's behaviour is
    ///   driven by `motion` (0 idle / 1 listening / 2 processing / 3 speaking / 4 interrupted),
    ///   `amplitude` (size & brightness pulse), `intensity` (overall brightness) and `color`.
    ///   Output alpha = orb coverage + glow, so it composites additively over the clear panel.
    public static let shaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    // Mirror of the Swift OrbUniforms - three float4s, identical byte layout.
    struct OrbUniforms {
        float4 p0; // (time, amplitude, intensity, motion)
        float4 p1; // (resWidthPx, resHeightPx, stateBlend, pad)
        float4 p2; // (colorR, colorG, colorB, pad)
    };

    struct VSOut {
        float4 position [[position]];
        float2 uv;       // 0..1 across the viewport
    };

    // Full-screen triangle: 3 vertices, no vertex buffer.
    vertex VSOut orbVertex(uint vid [[vertex_id]]) {
        float2 pos = float2((vid == 2) ? 3.0 : -1.0,
                            (vid == 1) ? 3.0 : -1.0);
        VSOut out;
        out.position = float4(pos, 0.0, 1.0);
        out.uv = float2(pos.x * 0.5 + 0.5, 1.0 - (pos.y * 0.5 + 0.5));
        return out;
    }

    // --- noise helpers -------------------------------------------------------

    static inline float saturatef(float x) { return clamp(x, 0.0, 1.0); }

    static inline float hash21(float2 p) {
        p = fract(p * float2(123.34, 345.45));
        p += dot(p, p + 34.345);
        return fract(p.x * p.y);
    }

    static inline float vnoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        float a = hash21(i + float2(0.0, 0.0));
        float b = hash21(i + float2(1.0, 0.0));
        float c = hash21(i + float2(0.0, 1.0));
        float d = hash21(i + float2(1.0, 1.0));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    static inline float fbm(float2 p) {
        float v = 0.0;
        float a = 0.5;
        float2x2 m = float2x2(1.6, 1.2, -1.2, 1.6);
        for (int i = 0; i < 4; i++) {
            v += a * vnoise(p);
            p = m * p;
            a *= 0.5;
        }
        return v;
    }

    // Emissive plasma tone: keep accent saturated, only a tiny hot core nears white.
    static inline float3 plasmaTone(float3 accent, float3 hotAccent, float energy) {
        float3 col = mix(accent, hotAccent, saturatef(energy * 0.55));
        float whiteMix = smoothstep(1.35, 2.1, energy) * 0.6;
        col = mix(col, float3(1.0), whiteMix);
        float lum = energy / (1.0 + energy * 0.65); // Reinhard knee
        return col * lum * 1.55;
    }

    fragment float4 orbFragment(VSOut in [[stage_in]],
                                constant OrbUniforms& u [[buffer(0)]]) {
        float  time      = u.p0.x;
        float  amp       = saturatef(u.p0.y);
        float  intensity = saturatef(u.p0.z);
        float  motion    = u.p0.w;
        float2 res       = max(u.p1.xy, float2(1.0, 1.0));
        float3 accent    = u.p2.xyz;

        // Aspect-correct, centered coordinates.
        float2 p  = (in.uv - 0.5) * 2.0;
        p.x *= res.x / res.y;
        float dist = length(p);

        // ---- smooth motion-band weights (no hard transitions) ----
        float wIdle    = 1.0 - smoothstep(0.0, 0.5, motion);
        float wListen  = smoothstep(0.0, 1.0, motion) * (1.0 - smoothstep(1.0, 2.0, motion));
        float wProcess = smoothstep(1.0, 2.0, motion) * (1.0 - smoothstep(2.0, 3.0, motion));
        float wSpeak   = smoothstep(2.0, 3.0, motion) * (1.0 - smoothstep(3.0, 4.0, motion));
        float wInterr  = smoothstep(3.0, 4.0, motion);

        float flash = exp(-fract(time) * 5.0);

        // ---- BREATHING: idle breathes deeply & slowly; listening is quicker/alert ----
        float slowBreath = sin(time * 0.8);              // ~0.13 Hz, deep and calm
        float fastBreath = sin(time * 2.4);              // attentive listening pulse
        float breathe = 0.050 * wIdle * slowBreath
                      + 0.016 * wListen * fastBreath;

        // ---- core radius per state ----
        float ampGrow  = amp * (0.12 * wListen + 0.14 * wSpeak);
        float contract = wInterr * (-0.12 + flash * 0.07);   // interrupted: sharp pull-in
        float coreR    = 0.30 + breathe + ampGrow + contract;

        // ---- domain-warped flow field (fbm of fbm); speed encodes the state ----
        float flowSpeed = 0.05 * wIdle
                        + (0.12 + amp * 0.30) * wListen
                        + 0.40 * wProcess                 // thinking churns fastest, amp-decoupled
                        + (0.20 + amp * 0.25) * wSpeak
                        + (0.05 + flash * 0.5) * wInterr;
        float t = time * flowSpeed;
        float warpAmt = 0.55 + 0.55 * wProcess + amp * 0.35 * (wListen + wSpeak);

        float2 q = float2(fbm(p * 2.2 + float2(0.0, t)),
                          fbm(p * 2.2 + float2(5.2, -t) + 1.7));
        float2 r = float2(fbm(p * 2.6 + q * warpAmt + float2(1.7, 9.2) + t * 0.7),
                          fbm(p * 2.6 + q * warpAmt + float2(8.3, 2.8) - t * 0.5));
        float flow = fbm(p * 3.0 + r * (warpAmt + 0.4) + t * 0.9) - 0.5;

        // state-specific surface motion
        float speakWave  = sin(dist * 20.0 - time * 6.0) * (0.12 + amp * 0.28) * wSpeak;
        float listenWave = sin(dist * 13.0 - time * 3.2) * (0.05 + amp * 0.35) * wListen;

        // ---- emissive volume (no sphere shading, no rim) ----
        float rr = dist / max(coreR, 0.001);
        float body    = exp(-rr * rr * 2.4);     // soft luminous core
        float halo    = exp(-dist * 3.1) * 0.50; // additive bloom (tighter)
        float farGlow = exp(-dist * 2.5) * 0.10; // broad ambient bloom (smaller halo)

        float filaments = (flow + speakWave + listenWave);
        float interior = body * (1.0 + filaments * 1.2);
        interior = max(interior, body * 0.35);   // luminous floor

        // ---- THINKING: a bright nucleus orbits the core during processing ----
        float orbAng = time * 1.8;
        float2 dp1 = p - float2(cos(orbAng), sin(orbAng)) * (coreR * 0.5);
        float nucleus = exp(-dot(dp1, dp1) * 34.0) * wProcess * (0.8 + 0.2 * sin(time * 6.0));
        float2 dp2 = p - float2(cos(-orbAng * 0.7), sin(-orbAng * 0.7)) * (coreR * 0.32);
        float nucleus2 = exp(-dot(dp2, dp2) * 60.0) * wProcess * 0.4;
        float churn = wProcess * saturatef(flow * 2.0) * body * 0.5;

        // ---- compose energy ----
        float energy = interior + halo + farGlow + churn + nucleus + nucleus2;

        float idleGlow   = 0.65 + 0.35 * (0.5 + 0.5 * slowBreath);  // idle glows with the breath
        float ampBright  = 1.0 + amp * (0.8 * wListen + 0.7 * wSpeak);
        float stateBright = idleGlow * wIdle + 1.05 * wListen + 1.1 * wProcess
                          + 1.15 * wSpeak + (0.7 + flash * 1.5) * wInterr;
        energy *= mix(0.45, 1.25, intensity) * ampBright * stateBright;

        // ---- colour: cool accent drifting cyan -> violet with energy/state ----
        float3 violet = float3(saturatef(accent.x * 0.75 + 0.30),
                               saturatef(accent.y * 0.40),
                               saturatef(accent.z + 0.12));
        float drift = 0.5 + 0.5 * sin(time * 0.13);
        float driftMix = saturatef(0.25 + 0.55 * drift
                                   + 0.40 * (wProcess + wInterr) + amp * 0.20);
        float3 hotAccent = mix(accent, violet, driftMix);
        float3 rgb = plasmaTone(accent, hotAccent, energy);

        // ---- alpha + radial edge window (kills the square halo on light backgrounds) ----
        float alpha = saturatef(body * 1.05 + halo * 0.8 + farGlow * 0.6
                                + churn * 0.5 + (nucleus + nucleus2) * 0.7);
        // Fade the whole field to EXACTLY 0 before the panel edge so no faint square
        // tail shows on a white background (invisible on dark, clean on light).
        float edgeWin = 1.0 - smoothstep(0.50, 0.78, dist);
        alpha *= edgeWin;
        rgb = min(rgb, float3(1.3));
        return float4(rgb * alpha, alpha);
    }
    """

    // MARK: Metal objects

    private let metalLayer = CAMetalLayer()
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var pipelineBuildAttempted = false

    // MARK: Display link / timing

    private var displayLink: CADisplayLink?
    private let startTime = CACurrentMediaTime()

    // MARK: Public API

    /// Called on the MAIN THREAD each display tick to obtain the uniforms for this frame.
    /// The argument is the elapsed time in seconds since view creation. When `nil`, a calm
    /// default is rendered.
    public var frameProvider: (@MainActor (Double) -> OrbUniforms)?

    /// Stops/starts the display link. Pausing saves power when the HUD is hidden.
    public var isPaused: Bool = false {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused {
                displayLink?.isPaused = true
            } else {
                ensureDisplayLink()
                displayLink?.isPaused = false
            }
        }
    }

    // MARK: Init

    public override init(frame frameRect: NSRect) {
        // Resolve a Metal device once; tolerate absence (headless/unsupported) gracefully.
        let dev = MTLCreateSystemDefaultDevice()
        self.device = dev
        self.commandQueue = dev?.makeCommandQueue()
        super.init(frame: frameRect)
        configureLayer()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for OrbMetalView")
    }

    // MARK: Layer setup

    /// Use our `CAMetalLayer` as the view's backing layer.
    public override func makeBackingLayer() -> CALayer {
        metalLayer
    }

    private func configureLayer() {
        wantsLayer = true
        layer = metalLayer

        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false                       // transparent HUD compositing
        metalLayer.backgroundColor = NSColor.clear.cgColor
        // Premultiplied alpha so additive glow composites correctly over the clear panel.
        metalLayer.compositingFilter = nil
        metalLayer.allowsNextDrawableTimeout = true

        // High-DPI: keep the drawable in physical pixels.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? metalLayer.contentsScale
        metalLayer.contentsScale = scale
        let size = bounds.size
        let px = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        if metalLayer.drawableSize != px {
            metalLayer.drawableSize = px
        }
    }

    // MARK: View lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            configureLayer()
            ensureDisplayLink()
            displayLink?.isPaused = isPaused
        } else {
            teardownDisplayLink()
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    public override func layout() {
        super.layout()
        updateDrawableSize()
    }

    // The display link is owned by, and invalidated through, the view's window lifecycle:
    // `viewDidMoveToWindow(nil)` calls `teardownDisplayLink()`. We deliberately do NOT touch
    // it from `deinit` because, under Swift 6 strict concurrency, a @MainActor class's deinit
    // is nonisolated and may not access the non-Sendable `CADisplayLink` stored property.
    // (A view that is deinitialized has already left its window, so the link is gone.)

    // MARK: Display link

    private func ensureDisplayLink() {
        guard displayLink == nil else { return }
        // macOS 14+ : NSView vends a CADisplayLink synced to the view's screen; fires on the
        // main thread, so all rendering stays on the main actor.
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        link.isPaused = isPaused
        displayLink = link
    }

    private func teardownDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard !isPaused else { return }
        render()
    }

    // MARK: Pipeline (lazy, tolerant)

    private func ensurePipeline() {
        guard pipelineState == nil, !pipelineBuildAttempted else { return }
        pipelineBuildAttempted = true
        guard let device else {
            NSLog("OrbMetalView: no Metal device available; orb will not render.")
            return
        }
        do {
            pipelineState = try Self.makePipeline(device: device)
        } catch {
            NSLog("OrbMetalView: shader pipeline build failed: \(error.localizedDescription)")
            pipelineState = nil
        }
    }

    /// Compiles `shaderSource` at runtime and builds the render pipeline with alpha blending
    /// enabled so the orb composites over the clear HUD panel. Exposed statically so headless
    /// tests can verify the shader compiles without a window or display link.
    public static func makePipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        let options = MTLCompileOptions()
        let library = try device.makeLibrary(source: shaderSource, options: options)

        guard let vertexFn = library.makeFunction(name: vertexFunctionName) else {
            throw OrbError.functionMissing(vertexFunctionName)
        }
        guard let fragmentFn = library.makeFunction(name: fragmentFunctionName) else {
            throw OrbError.functionMissing(fragmentFunctionName)
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.label = "flowcode.orb.pipeline"
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn

        let color = desc.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        // Premultiplied-alpha blending: src is already premultiplied (rgb * alpha in shader),
        // so use ONE for source RGB and (1 - srcAlpha) for destination.
        color.isBlendingEnabled = true
        color.rgbBlendOperation = .add
        color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        return try device.makeRenderPipelineState(descriptor: desc)
    }

    // MARK: Render

    private func render() {
        ensurePipeline()
        guard
            let device,
            let commandQueue,
            let pipelineState
        else { return }
        _ = device // device is implicitly used via the layer; silence unused in some configs.

        // Keep drawable size in sync (handles screen / DPI changes between ticks).
        updateDrawableSize()
        guard metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0 else { return }
        guard let drawable = metalLayer.nextDrawable() else { return }

        let elapsed = CACurrentMediaTime() - startTime

        var uniforms: OrbUniforms = frameProvider?(elapsed) ?? OrbUniforms.makeDefault(
            time: Float(elapsed),
            resWidthPx: Float(metalLayer.drawableSize.width),
            resHeightPx: Float(metalLayer.drawableSize.height)
        )
        // Always stamp the real resolution so the shader's aspect correction is exact,
        // regardless of what the provider supplied.
        uniforms.p1.x = Float(metalLayer.drawableSize.width)
        uniforms.p1.y = Float(metalLayer.drawableSize.height)

        let passDesc = MTLRenderPassDescriptor()
        let att = passDesc.colorAttachments[0]!
        att.texture = drawable.texture
        att.loadAction = .clear
        att.storeAction = .store
        att.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0) // fully transparent

        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc)
        else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms,
                                 length: MemoryLayout<OrbUniforms>.stride,
                                 index: 0)
        // Full-screen triangle: 3 vertices, no vertex buffer (positions from vertex_id).
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: Errors

    enum OrbError: Error, CustomStringConvertible {
        case functionMissing(String)

        var description: String {
            switch self {
            case .functionMissing(let name):
                return "OrbMetalView: shader function '\(name)' not found in compiled library"
            }
        }
    }
}
