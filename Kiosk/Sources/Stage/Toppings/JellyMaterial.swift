import Metal
import RealityKit

@MainActor
enum JellyMaterial {
    struct Flavor {
        /// Linear color of the jelly's body over a white background.
        let color: SIMD3<Float>
        /// Share of the background seen through the thickest jelly; thin parts and silhouettes show more.
        let see: Float
    }

    static let library: Result<MTLLibrary, Error> = Result {
        guard let device = MTLCreateSystemDefaultDevice() else { throw CocoaError(.featureUnsupported) }
        return try device.makeLibrary(source: source, options: nil)
    }

    static func make(_ flavor: Flavor) throws -> CustomMaterial {
        let library = try library.get()
        var material = try CustomMaterial(surfaceShader: .init(named: "gummyJelly", in: library), lightingModel: .lit)
        material.custom.value = SIMD4(flavor.color, flavor.see)
        material.faceCulling = .back
        // A bear's own overlapping faces near its silhouette would otherwise occlude each other in triangle order.
        material.writesDepth = false
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        return material
    }

    // The runtime compiler can't see <RealityKit/RealityKit.h>, so the few entry points used are declared here with the
    // header's exact namespaces and signatures; RealityKit links them by their mangled names.
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    namespace realitykit {
    namespace surface {
    struct surface_data_t;
    namespace api {
    [[visible]] float4 custom_parameter(thread surface_data_t &data);
    [[visible]] float3 model_position(thread surface_data_t &data);
    [[visible]] float3 view_direction(thread surface_data_t &data);
    [[visible]] float3 geometry_normal(thread surface_data_t &data);
    [[visible]] float2 uv0(thread surface_data_t &data);
    [[visible]] void set_base_color(half3 value, thread surface_data_t &data);
    [[visible]] void set_emissive_color(half3 value, thread surface_data_t &data);
    [[visible]] void set_roughness(half value, thread surface_data_t &data);
    [[visible]] void set_metallic(half value, thread surface_data_t &data);
    [[visible]] void set_specular(half value, thread surface_data_t &data);
    [[visible]] void set_opacity(half value, thread surface_data_t &data);
    }
    }
    struct surface_parameters {
        thread surface::surface_data_t &data;
    };
    }

    using namespace realitykit::surface;

    static float hash3(float3 p) {
        p = fract(p * 0.3183099 + 0.1);
        p *= 17.0;
        return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
    }

    static float noise3(float3 p) {
        float3 i = floor(p);
        float3 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        return mix(mix(mix(hash3(i), hash3(i + float3(1, 0, 0)), f.x),
                       mix(hash3(i + float3(0, 1, 0)), hash3(i + float3(1, 1, 0)), f.x), f.y),
                   mix(mix(hash3(i + float3(0, 0, 1)), hash3(i + float3(1, 0, 1)), f.x),
                       mix(hash3(i + float3(0, 1, 1)), hash3(i + float3(1, 1, 1)), f.x), f.y), f.z);
    }

    [[visible]]
    void gummyJelly(realitykit::surface_parameters params) {
        thread surface_data_t &d = params.data;
        float4 jelly = api::custom_parameter(d);
        float2 shade = api::uv0(d);
        float3 n = normalize(api::geometry_normal(d));
        float3 v = normalize(api::view_direction(d));
        float facing = saturate(dot(n, v));
        float3 p = api::model_position(d) * 1000.0;
        float mottle = noise3(p * 0.8) * 0.65 + noise3(p * 2.0 + 7.0) * 0.35;

        float3 body = max(jelly.rgb, 0.001);
        float edge = 1.0 - facing;
        float thick = saturate((shade.y - 0.12) / 0.33) * mix(1.0, 0.35, edge * edge);
        thick = saturate(thick * (0.8 + 0.4 * mottle));

        float light = dot(body, float3(0.2126, 0.7152, 0.0722));
        float haze = 0.05 + 0.05 * mottle + 0.1 * light * light;
        float see = mix(mix(jelly.w, 1.0, 0.25 + 0.3 * light), jelly.w, thick) * (1.0 - haze);
        float opacity = 1.0 - see;

        // Toward the stage's key and back lights (Stage.configureScene).
        float3 key = normalize(float3(-1.3, 1.6, 2.2));
        float3 back = normalize(float3(0.35, 1.5, -2.2));
        float wrap = saturate(dot(n, key) * 0.5 + 0.5);
        float through = pow(saturate(dot(-n, back) * 0.6 + 0.4), 2.0) * (1.0 - 0.5 * thick);
        float3 tint = mix(pow(body, 0.7) * 1.1, pow(body, 1.25) * 0.9, thick);
        float3 target = tint * (0.4 + 0.5 * wrap + 0.6 * through);
        float3 frost = haze * mix(float3(1.0), body, 0.6) * (0.4 + 0.6 * wrap) * (1.0 + 0.8 * light);
        float shown = see * 0.8;
        float3 filtered = mix(max(target - shown, 0.0), target * saturate(1.0 - shown / max(dot(target, float3(0.2126, 0.7152, 0.0722)), 0.01)), light * light);
        float3 emitted = filtered + frost;

        api::set_base_color(half3(tint * 0.05), d);
        // RealityKit scales the whole shaded color by opacity; dividing it back out adds the glow on top of the
        // dimmed background instead of fading it with the background's share.
        api::set_emissive_color(half3(emitted / max(opacity, 0.05)), d);
        api::set_roughness(half(0.4 + 0.1 * mottle), d);
        api::set_metallic(half(0.0), d);
        api::set_specular(half(0.7), d);
        api::set_opacity(half(opacity), d);
    }
    """
}
