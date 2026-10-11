# 3D asset contract

All assets: meters, RealityKit convention (+Y up, camera looks down -Z, front of objects faces +Z).

## Containers
- `Cup.usdz`  — origin at the center of the cup's bottom (y = 0 is the table). Real top Ø 87.5 mm, height 46.3 mm.
- `Cone.usdz` — origin at the cone tip, axis = +Y. ~55 × 57 × 136 mm.
  The low side of the slanted rim faces +Z (toward the default camera), so the default view looks into the opening.

## Scoops — `Scoop{N}.scoopmesh` (N = 1, 2, 3 = which scoop slot of an item it is used for)
One mesh per slot, several poses with identical topology so the app can morph between them per frame.
Little-endian binary:

    char[4]  magic "SCMP"
    u32      version (1)
    u32      vertexCount
    u32      indexCount           (triangles, so a multiple of 3)
    u32      poseCount
    poseCount × { u32 byteLength, utf8 name }
    f32[vertexCount*2]            uv (shared by all poses, v up, origin bottom-left like USD)
    u32[indexCount]               indices, counter-clockwise front faces
    poseCount × {
        f32[vertexCount*3]        positions
        f32[vertexCount*3]        normals
        f32[vertexCount*4]        tangents (xyz, w = bitangent sign)
    }

Poses (all in the scoop's own local frame: origin = center of the scoop's base, +Y up):
- `icon`      resting on a flat surface (the look of scoops_flavors.png); base touches y = 0.
- `ball`      nearly round, used mid-flight.
- `cup`       deformed to sit in a cup at this slot (when the cup has ≥ 2 scoops, or for slots 2–3).
- `cup_solo`  only in Scoop1: the single-scoop-in-cup variant (sits a bit higher).
- `cone`      deformed to sit on a cone at this slot.

## Placement — `placements.json`
Where a scoop's local frame goes inside the container's frame once it has landed:

    { "cup":  { "solo": T, "1": T, "2": T, "3": T },
      "cone": { "1": T, "2": T, "3": T } }
    T = { "translation": [x, y, z], "rotation": [x, y, z, w] }   // quaternion, local → container

## Scoop textures — `Scoop{N}_{flavor}_{map}.png`, 2048²
flavor ∈ vanilla, chocolate, cookies · map ∈ basecolor (sRGB), normal (linear, tangent space, OpenGL +Y), roughness (linear, R channel)

## Lighting — `studio.exr`
Equirectangular HDR environment for ImageBasedLightComponent so the app matches the Blender look.

## Environment orientation (verified in RealityKit on macOS with a mirror sphere)
- `studio.exr` as authored has the image center facing +Z (front of the object) with image-right = -X.
  RealityKit's equirectangular convention is different: the image center maps to -Z, the left/right image edges meet at +Z,
  u in (0, 0.5) is the -X side and u in (0.5, 1) is the +X side.
- Result: with no rotation the key panel lands behind the object. Rotate the IBL by 180 degrees about Y.
- Required setup (without `inheritsRotation = true` the entity's rotation is ignored, which was observed):

      var ibl = ImageBasedLightComponent(source: .single(env), intensityExponent: 0)
      ibl.inheritsRotation = true
      iblEntity.components.set(ibl)
      iblEntity.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
      // every lit entity: ImageBasedLightReceiverComponent(imageBasedLight: iblEntity)

- With that, a viewer at +Z looking toward -Z sees the key from front-left-above, the fill from front-right, the rim from behind-above.
- Load the EXR as a CGImage (CGImageSourceCreateWithURL, 16-bit float) and call `EnvironmentResource(equirectangular:)`.

## UV convention (verified)
- UVs in `.scoopmesh` are v-up (origin bottom-left), exactly as baked. Textures are correct without flipping v in Blender,
  and a RealityKit `MeshDescriptor` test (v = 1 at the top vertex shows the top row of the image) confirmed no flip is needed there either.

## Toppings — `GummyBear.usdz`
One untextured mesh prim (`/GummyBear`, default prim), meters, Y up, about 12.0 × 7.8 × 20 mm. Posed as a scattered piece
rests: lying on its back (back on -Y, belly +Y), head toward -Z, bounding box centered on the origin. Its `st` primvar is
shading data, not a texture layout: u = |normal · Y| (1 face-on to the belly or back, 0 on the side walls), v = jelly
thickness along the inward normal divided by twice the bear's depth, clamped to 1. Materials are set in code
(`CandyKinds.swift`). Built from `Assets3D/gummy_bears` (Styro, CC-BY-4.0) by `Assets3D/pipeline/gummy_bear.py`.
