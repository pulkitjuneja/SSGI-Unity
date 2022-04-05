using System.Collections;
using System.Collections.Generic;
using UnityEngine;

public class CreateCustomDiffuseNormals : MonoBehaviour
{

    public Material customNormals;
    public Texture noise;
    private Camera m_camera;

    private void DrawFullScreenQuad()
    {
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

    void Awake()
    {
        noise = Resources.Load("tex_BlueNoise_1024x1024_UNI") as Texture2D;
        m_camera = GetComponent<Camera>();
        m_camera.depthTextureMode |= DepthTextureMode.Depth | DepthTextureMode.MotionVectors;
        SSGIMaterial = new Material(Shader.Find("Hidden/CreateCustomNormals"));
    }

    private void OnPreCull()
    {
    }

    [ImageEffectOpaque]
    private void OnRenderImage(RenderTexture source, RenderTexture destination)
    {
        int width = m_camera.pixelWidth;
        int height = m_camera.pixelHeight;
        SSGIMaterial.SetVector("_ScreenSize", new Vector2((float)width, (float)height));
        SSGIMaterial.SetTexture("_Noise", noise);
        SSGIMaterial.SetVector("_NoiseSize", new Vector2(noise.width, noise.height));

    }
}
