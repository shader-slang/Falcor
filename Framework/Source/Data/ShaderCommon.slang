
__exported import ShaderCommonImpl;
__import Shading;
__import Interfaces;
__import Lights;
__generic_param TMaterial : IMaterial;
type_param TLightEnv : ILight;
typedef ShadingAttribsImpl<TMaterial.EvaluatedMaterial> ShadingAttribs;
ParameterBlock<TMaterial> gMaterial;
ParameterBlock<TLightEnv> gLightEnv;