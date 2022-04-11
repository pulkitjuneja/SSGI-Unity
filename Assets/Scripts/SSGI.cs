using System.Collections;
using System.Collections.Generic;
using UnityEngine;

[System.Serializable]
public enum ResolutionMode
{
    halfRes = 2,
    fullRes = 1,
};

public class SSGI : MonoBehaviour
{
    [Header("Raymarch Settings")]
    public ResolutionMode depthResolution = ResolutionMode.halfRes;
    public ResolutionMode reflectionResoluttion = ResolutionMode.halfRes;
    public ResolutionMode resolveResolution = ResolutionMode.fullRes;
    public int rayDistance = 70;
    [Range(0.0f, 1.0f)] public float BRDFBias = 0.7f;
    Texture noise;
    public bool rayReuse = true;
    [Range(0.0f, 1.0f)] public float edgeFade = 0.125f;
    public bool useIndirect = true;
    public bool usePrevFrame = true;


    [Header("temporal")]
    public bool useTemporal = true;
    public float scale = 2.0f;
    [Range(0.0f, 1.0f)] public float response = 0.95f;

    [Header("blur")]
    [Range(0.0f, 1.0f)] public float blurSize = 0.1f;
    [Range(0.0f, 0.3f)] public float standardDeviation = 0.15f;
    [Range(0.0f, 200.0f)] public float depthBlurFalloff = 100f;

    //Uniforms
    private Camera m_camera;
    private Matrix4x4 projectionMatrix;
    private Matrix4x4 viewProjectionMatrix;
    private Matrix4x4 inverseViewProjectionMatrix;
    private Matrix4x4 viewMatrix;
    private int frameCount = 0;
    // private Matrix4x4 inverseViewMatrix;

    // Maybe not required unity calculates motion for us 
    private Matrix4x4 prevViewProjectionMatrix;

    RenderTexture temporalReflectionBuffer;
    RenderTexture prevFrameBuffer;
    RenderTexture prevFrameDiffuseBuffer;
    RenderTexture currentFrameBuffer;
    RenderTexture previousFrameFinalColor;
    Material SSGIMaterial;
    Material gaussianBlur;
    Vector2 jitter;
    int m_SampleIndex = 0;
    const int k_SampleCount = 64;

     public static RenderTexture CreateRenderTexture(int w, int h, int d, RenderTextureFormat f, bool useMipMap, bool generateMipMap, FilterMode filterMode) {
        RenderTexture r = new RenderTexture(w, h, d, f);
        r.filterMode = filterMode;
        r.useMipMap = useMipMap;
        r.autoGenerateMips = generateMipMap;
        r.Create();
        return r;
    }

    private RenderTexture CreateTempBuffer(int x, int y, int depth, RenderTextureFormat format) {
        return RenderTexture.GetTemporary(x, y, depth, format);
    }

    private void ReleaseRenderTargets() {

        if (temporalReflectionBuffer != null)
        {
            temporalReflectionBuffer.Release();
            temporalReflectionBuffer = null;
        }

        if (currentFrameBuffer != null || prevFrameBuffer != null)
        {
            currentFrameBuffer.Release();
            currentFrameBuffer = null;
            prevFrameBuffer.Release();
            prevFrameBuffer = null;
        }

        if (prevFrameDiffuseBuffer != null)
        {
            prevFrameDiffuseBuffer.Release();
            prevFrameDiffuseBuffer = null;
        }


        if (previousFrameFinalColor != null)
        {
            previousFrameFinalColor.Release();
            previousFrameFinalColor = null;
        }
    }

    private void ReleaseTempBuffer(RenderTexture rt) {
            RenderTexture.ReleaseTemporary(rt);
    }

    private void UpdateRenderTargets(int width, int height) {
        if (temporalReflectionBuffer != null && temporalReflectionBuffer.width != width) {
            ReleaseRenderTargets();
        }

        if (temporalReflectionBuffer == null || !temporalReflectionBuffer.IsCreated()) {
            temporalReflectionBuffer = CreateRenderTexture(width, height, 0, RenderTextureFormat.Default, false, false, FilterMode.Bilinear);

        }

        if (prevFrameDiffuseBuffer == null || !prevFrameDiffuseBuffer.IsCreated())
        {
            prevFrameDiffuseBuffer = CreateRenderTexture(width, height, 0, RenderTextureFormat.ARGBFloat, false, false, FilterMode.Bilinear);

        }

        if (previousFrameFinalColor == null || !previousFrameFinalColor.IsCreated())
        {
            previousFrameFinalColor = CreateRenderTexture(width, height, 0, RenderTextureFormat.ARGBFloat, false, false, FilterMode.Bilinear);

        }

        if (currentFrameBuffer == null || !currentFrameBuffer.IsCreated()) {
            currentFrameBuffer = CreateRenderTexture(width, height, 0, RenderTextureFormat.Default, false, false, FilterMode.Bilinear);
            prevFrameBuffer = CreateRenderTexture(width, height, 0, RenderTextureFormat.Default, false, false, FilterMode.Bilinear);
        }
    }

    private void UpdateUniforms() {
        SSGIMaterial.SetTexture("_Noise", noise);
        SSGIMaterial.SetVector("_NoiseSize", new Vector2(noise.width, noise.height));
        SSGIMaterial.SetFloat("_BRDFBias", BRDFBias);
        SSGIMaterial.SetFloat("_SmoothnessRange", 1.0f);
        SSGIMaterial.SetFloat("_EdgeFactor", edgeFade);
        SSGIMaterial.SetInt("_NumSteps", rayDistance);
        // SSGIMaterial.SetFloat("_Thickness", 0.1f);

        if (!rayReuse)
            SSGIMaterial.SetInt("_RayReuse", 0);
        else
            SSGIMaterial.SetInt("_RayReuse", 1);
        if (!useTemporal)
            SSGIMaterial.SetInt("_UseTemporal", 0);
        else if (useTemporal && Application.isPlaying)
            SSGIMaterial.SetInt("_UseTemporal", 1);

        if (!useIndirect)
            SSGIMaterial.SetInt("_EnableIndirectLighting", 0);
        else if (useIndirect && Application.isPlaying)
            SSGIMaterial.SetInt("_EnableIndirectLighting", 1);

        SSGIMaterial.SetInt("_FrameCount", frameCount++);

        // SSGIMaterial.SetInt("_ReflectionVelocity", 1);
        // SSGIMaterial.SetInt("_UseFresnel", 1);
        // SSGIMaterial.SetInt("_UseNormalization", 1);
        // SSGIMaterial.SetInt("_Fireflies", 1);

        viewMatrix = m_camera.worldToCameraMatrix;
        projectionMatrix = GL.GetGPUProjectionMatrix(m_camera.projectionMatrix, false);
        viewProjectionMatrix = projectionMatrix * viewMatrix;
        inverseViewProjectionMatrix = viewProjectionMatrix.inverse;
        SSGIMaterial.SetMatrix("_ProjectionMatrix", projectionMatrix);
        // SSGIMaterial.SetMatrix("_ViewProjectionMatrix", viewProjectionMatrix);
        SSGIMaterial.SetMatrix("_InverseProjectionMatrix", projectionMatrix.inverse);
        SSGIMaterial.SetMatrix("_InverseViewProjectionMatrix", inverseViewProjectionMatrix);
        SSGIMaterial.SetMatrix("_WorldToCameraMatrix", viewMatrix);
    }

    private float GetHaltonValue(int index, int radix){
        float result = 0f;
        float fraction = 1f / (float)radix;

        while (index > 0)
        {
            result += (float)(index % radix) * fraction;

            index /= radix;
            fraction /= (float)radix;
        }

        return result;
    }

    private Vector2 GenerateRandomOffset() {
        var offset = new Vector2(
                GetHaltonValue(m_SampleIndex & 1023, 2),
                GetHaltonValue(m_SampleIndex & 1023, 3));

        if (++m_SampleIndex >= k_SampleCount)
            m_SampleIndex = 0;

        return offset;
    }

    private void DrawFullScreenQuad() {
        GL.PushMatrix();
        GL.LoadOrtho();

        GL.Begin(GL.QUADS);
        GL.MultiTexCoord2(0, 0.0f, 0.0f);
        GL.Vertex3(0.0f, 0.0f, 0.0f); // BL

        GL.MultiTexCoord2(0, 1.0f, 0.0f);
        GL.Vertex3(1.0f, 0.0f, 0.0f); // BR

        GL.MultiTexCoord2(0, 1.0f, 1.0f);
        GL.Vertex3(1.0f, 1.0f, 0.0f); // TR

        GL.MultiTexCoord2(0, 0.0f, 1.0f);
        GL.Vertex3(0.0f, 1.0f, 0.0f); // TL

        GL.End();
        GL.PopMatrix();
    }

    void Awake() {
        noise = Resources.Load("tex_BlueNoise_1024x1024_UNI") as Texture2D;
        m_camera = GetComponent<Camera>();
        m_camera.depthTextureMode |= DepthTextureMode.Depth | DepthTextureMode.MotionVectors;
        SSGIMaterial = new Material(Shader.Find("Effects/SSGI"));
        gaussianBlur = new Material(Shader.Find("Effects/GaussianBlur"));
    }

    private void OnPreCull() {
        jitter = GenerateRandomOffset();
    }

    private void RenderDiffuse(RenderTexture source, RenderTexture destination)
    {

    }

    private void DownscaleAndUpscale(RenderTexture source, ref RenderTexture result)
    {
        int width = m_camera.pixelWidth;
        int height = m_camera.pixelHeight;

        gaussianBlur.SetFloat("_StandardDeviation", standardDeviation);
        gaussianBlur.SetFloat("_BlurSize", blurSize);
        gaussianBlur.SetFloat("_DepthBlurFalloff", depthBlurFalloff);
        //mip 1
        RenderTexture tempTexture = CreateTempBuffer(width / 2, height / 2, 0, RenderTextureFormat.Default);
        //
        RenderTexture tempTexture2 = CreateTempBuffer(width / 4, height / 4, 0, RenderTextureFormat.Default);

        //blurring smallest texture
        {
            Graphics.Blit(source, tempTexture);
            Graphics.Blit(tempTexture, tempTexture2);

            RenderTexture tempTexture2Blur = CreateTempBuffer(width / 4, height / 4, 0, RenderTextureFormat.Default);
            Graphics.Blit(tempTexture2, tempTexture2Blur, gaussianBlur, 0);
            Graphics.Blit(tempTexture2Blur, tempTexture2, gaussianBlur, 1);

            RenderTexture tempTexture1Blur = CreateTempBuffer(width / 2, height / 2, 0, RenderTextureFormat.Default);
            Graphics.Blit(tempTexture2, tempTexture1Blur, gaussianBlur, 0);
            Graphics.Blit(tempTexture1Blur, tempTexture, gaussianBlur, 1);

            RenderTexture destinatitonBlur = CreateTempBuffer(width, height, 0, RenderTextureFormat.Default);
            Graphics.Blit(tempTexture, destinatitonBlur, gaussianBlur, 0);
            Graphics.Blit(destinatitonBlur, result, gaussianBlur, 1);
            ReleaseTempBuffer(tempTexture1Blur);
            ReleaseTempBuffer(tempTexture2Blur);
            ReleaseTempBuffer(destinatitonBlur);


        }

        ReleaseTempBuffer(tempTexture);
        ReleaseTempBuffer(tempTexture2);

    }

    private void RenderSpecular(RenderTexture source, RenderTexture destination)
    {
        int width = m_camera.pixelWidth;
        int height = m_camera.pixelHeight;
        UpdateRenderTargets(width, height);
        UpdateUniforms();

        int rayWidth = width / (int)reflectionResoluttion;
        int rayHeight = height / (int)reflectionResoluttion;

        int resolveWidth = width / (int)resolveResolution;
        int resolveHeight = height / (int)resolveResolution;

        SSGIMaterial.SetVector("_JitterSizeAndOffset",
        new Vector4((float)rayWidth / (float)noise.width, (float)rayHeight / (float)noise.height, jitter.x, jitter.y));
        SSGIMaterial.SetVector("_ScreenSize", new Vector2((float)width, (float)height));
        SSGIMaterial.SetVector("_RayCastSize", new Vector2((float)rayWidth, (float)rayHeight));
        SSGIMaterial.SetVector("_ResolveSize", new Vector2((float)resolveWidth, (float)resolveHeight));

        RenderTexture rayCast = CreateTempBuffer(rayWidth, rayHeight, 0, RenderTextureFormat.ARGBHalf);
        RenderTexture rayCastMask = CreateTempBuffer(rayWidth, rayHeight, 0, RenderTextureFormat.RHalf);
        rayCast.filterMode = FilterMode.Point;

        SSGIMaterial.SetTexture("_RayCast", rayCast);
        SSGIMaterial.SetTexture("_RayCastMask", rayCastMask);

        // initial reprojection, not sure why this is needed. looks same without it
        Graphics.Blit(prevFrameBuffer, currentFrameBuffer, SSGIMaterial, 0);

        RenderBuffer[] renderBuffer = new RenderBuffer[2];
        renderBuffer[0] = rayCast.colorBuffer;
        renderBuffer[1] = rayCastMask.colorBuffer;
        Graphics.SetRenderTarget(renderBuffer, rayCast.depthBuffer);
        SSGIMaterial.SetPass(1);
        DrawFullScreenQuad();

        RenderTexture reflectionBuffer = CreateTempBuffer(resolveWidth, resolveHeight, 0, RenderTextureFormat.Default);
        // TODO Implement Mip Map blur before resolve pass
        Graphics.Blit(currentFrameBuffer, reflectionBuffer, SSGIMaterial, 2);
        SSGIMaterial.SetTexture("_ReflectionBuffer", reflectionBuffer);

        ReleaseTempBuffer(rayCast);
        ReleaseTempBuffer(rayCastMask);

        if (useTemporal && Application.isPlaying)
        {
            SSGIMaterial.SetFloat("_TScale", scale);
            SSGIMaterial.SetFloat("_TResponse", response);

            RenderTexture temporalBuffer0 = CreateTempBuffer(width, height, 0, RenderTextureFormat.Default);
            SSGIMaterial.SetTexture("_PreviousBuffer", temporalReflectionBuffer);
            Graphics.Blit(reflectionBuffer, temporalBuffer0, SSGIMaterial, 3); // Temporal pass
            Graphics.Blit(temporalBuffer0, temporalReflectionBuffer);
            SSGIMaterial.SetTexture("_ReflectionBuffer", temporalReflectionBuffer);
            ReleaseTempBuffer(temporalBuffer0);
        }

        if(frameCount==0)
        {
            Graphics.Blit(source, previousFrameFinalColor);
        }

        RenderTexture customNormals = CreateTempBuffer(width, height, 0, RenderTextureFormat.ARGBFloat);
        Graphics.Blit(source, customNormals, SSGIMaterial, 5);

        RenderTexture diffuseIndirectBuffer = CreateTempBuffer(width, height, 0, RenderTextureFormat.ARGBFloat);

        if(usePrevFrame)
            SSGIMaterial.SetTexture("_SourceColor", previousFrameFinalColor);
        else
            SSGIMaterial.SetTexture("_SourceColor", source);

        Graphics.Blit(customNormals, diffuseIndirectBuffer, SSGIMaterial, 6);

        RenderTexture tempDiffuseBuffer = CreateTempBuffer(width, height, 0, RenderTextureFormat.Default);


        RenderTexture finalDiff = CreateTempBuffer(width, height, 0, RenderTextureFormat.Default);
        //downscaling and upscaling
        {
            DownscaleAndUpscale(diffuseIndirectBuffer, ref finalDiff);
        }
        Graphics.Blit(finalDiff, tempDiffuseBuffer);


        if (useTemporal && Application.isPlaying)
        {
            SSGIMaterial.SetFloat("_TScale", scale);
            SSGIMaterial.SetFloat("_TResponse", response);

            RenderTexture temporalBuffer0 = CreateTempBuffer(width, height, 0, RenderTextureFormat.ARGBFloat);
            SSGIMaterial.SetTexture("_PreviousBuffer", prevFrameDiffuseBuffer);
            Graphics.Blit(finalDiff, temporalBuffer0, SSGIMaterial, 3); // Temporal pass
            Graphics.Blit(temporalBuffer0, prevFrameDiffuseBuffer);
            Graphics.Blit(prevFrameDiffuseBuffer, tempDiffuseBuffer);
            ReleaseTempBuffer(temporalBuffer0);
        }

        SSGIMaterial.SetTexture("_DiffuseReflectionBuffer", tempDiffuseBuffer);
        Graphics.Blit(source, prevFrameBuffer, SSGIMaterial, 4);
        Graphics.Blit(prevFrameBuffer, destination);
        Graphics.Blit(destination, previousFrameFinalColor);
        ReleaseTempBuffer(customNormals);
        ReleaseTempBuffer(tempDiffuseBuffer);
        ReleaseTempBuffer(diffuseIndirectBuffer);

        //Graphics.Blit(prevFrameBuffer, destination);
        ReleaseTempBuffer(reflectionBuffer);
        ReleaseTempBuffer(finalDiff);

    }

    [ImageEffectOpaque]
    private void OnRenderImage(RenderTexture source, RenderTexture destination) 
    {
        RenderSpecular(source, destination);
        //RenderDiffuse(source, destination);
    }

    private void OnDisable() 
    {
        ReleaseRenderTargets();
    }
}
