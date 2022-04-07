#include "UnityStandardBRDF.cginc"

#define PI 3.141592

uniform sampler2D	_MainTex,
					_ReflectionBuffer,
					_DiffuseReflectionBuffer,
					_PreviousBuffer,
					_RayCast,
					_RayCastMask;

uniform	sampler2D	_Noise;

uniform	sampler2D	_SourceColor;

uniform sampler2D	_CameraGBufferTexture0,
					_CameraGBufferTexture1,
					_CameraGBufferTexture2,
					_CameraReflectionsTexture;
	
uniform sampler2D	_CameraDepthTexture; 
uniform sampler2D_half _CameraMotionVectorsTexture;

uniform float4		_ScreenSize;
uniform	float4		_RayCastSize;
uniform	float4		_ResolveSize;
uniform	float4		_NoiseSize;
uniform float4		_JitterSizeAndOffset; // x = jitter width / screen width, y = jitter height / screen height, z = random offset, w = random offset

uniform float		_EdgeFactor; 
uniform float		_SmoothnessRange;
uniform float		_BRDFBias;

uniform float		_TScale;
uniform float		_TMinResponse;
uniform float		_TMaxResponse;
uniform float		_TResponse;
uniform int			_NumSteps;
uniform int			_RayReuse;

uniform float4x4	_ProjectionMatrix;
uniform float4x4	_InverseProjectionMatrix;
uniform float4x4	_InverseViewProjectionMatrix;
uniform float4x4	_WorldToCameraMatrix;

//Debug Options
uniform int			_UseTemporal;
uniform int			_MaxMipMap;

float4 GetCubeMap (float2 uv) { return tex2D(_CameraReflectionsTexture, uv); }
float GetRoughness (float smoothness) { return max(min(_SmoothnessRange, 1 - smoothness), 0.05f); }
float4 GetNormal (float2 uv) 
{ 
	float4 gbuffer2 = tex2D(_CameraGBufferTexture2, uv);

	return gbuffer2*2-1;
}

float3 GetViewNormal (float3 normal)
{
	float3 viewNormal =  mul((float3x3)_WorldToCameraMatrix, normal.rgb);
	return normalize(viewNormal);
}

float GetDepth (sampler2D tex, float2 uv)
{
	float z = tex2Dlod(_CameraDepthTexture, float4(uv,0,0));
	#if defined(UNITY_REVERSED_Z)
		z = 1.0f - z;
	#endif
	return z;
}

float3 GetWorlPos (float3 screenPos)
{
	float4 worldPos = mul(_InverseViewProjectionMatrix, float4(screenPos, 1));
	return worldPos.xyz / worldPos.w;
}

float3 GetViewPos (float3 screenPos)
{
	float4 viewPos = mul(_InverseProjectionMatrix, float4(screenPos, 1));
	return viewPos.xyz / viewPos.w;
}

static const float2 offset[4] =
{
	float2(0, 0),
	float2(2, -2),
	float2(-2, -2),
	float2(0, 2)
};

float RayAttenBorder (float2 pos, float value)
{
	float borderDist = min(1.0 - max(pos.x, pos.y), min(pos.x, pos.y));
	return saturate(borderDist > value ? 1.0 : borderDist / value);
}

float BRDF(float3 V, float3 L, float3 N, float Roughness)
{
	float3 H = normalize(L + V);

	float NdotH = saturate(dot(N,H));
	float NdotL = saturate(dot(N,L));
	float NdotV = saturate(dot(N,V));

	half G = SmithJointGGXVisibilityTerm (NdotL, NdotV, Roughness);
	half D = GGXTerm (NdotH, Roughness);

	return (D * G) * (UNITY_PI / 4.0);
}

float4 TangentToWorld(float3 N, float4 H)
{
	float3 UpVector = abs(N.z) < 0.999 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
	float3 T = normalize( cross( UpVector, N ) );
	float3 B = cross( N, T );
				 
	return float4((T * H.x) + (B * H.y) + (N * H.z), H.w);
}

// Brian Karis, Epic Games "Real Shading in Unreal Engine 4"
float4 ImportanceSampleGGX(float2 Xi, float Roughness)
{
	float m = Roughness * Roughness;
	float m2 = m * m;
		
	float Phi = 2 * PI * Xi.x;
				 
	float CosTheta = sqrt((1.0 - Xi.y) / (1.0 + (m2 - 1.0) * Xi.y));
	float SinTheta = sqrt(max(1e-5, 1.0 - CosTheta * CosTheta));
				 
	float3 H;
	H.x = SinTheta * cos(Phi);
	H.y = SinTheta * sin(Phi);
	H.z = CosTheta;
		
	float d = (CosTheta * m2 - CosTheta) * CosTheta + 1;
	float D = m2 / (PI * d * d);
	float pdf = D * CosTheta;

	return float4(H, pdf); 
}

float4 RayMarch(sampler2D tex, float4x4 _ProjectionMatrix, float3 viewDir, int NumSteps, float3 viewPos, float3 screenPos, float2 screenUV, float stepSize, float thickness)
{
	//float3 dirProject = _Project;
	float4 dirProject = float4
	(
		abs(unity_CameraProjection._m00 * 0.5), 
		abs(unity_CameraProjection._m11 * 0.5), 
		((_ProjectionParams.z * _ProjectionParams.y) / (_ProjectionParams.y - _ProjectionParams.z)) * 0.5,
		0.0
	);

	float linearDepth  =  LinearEyeDepth(tex2D(tex, screenUV.xy));

	float3 ray = viewPos / viewPos.z;
	float3 rayDir = normalize(float3(viewDir.xy - ray * viewDir.z, viewDir.z / linearDepth) * dirProject);
	rayDir.xy *= 0.5;

	float3 rayStart = float3(screenPos.xy * 0.5 + 0.5,  screenPos.z);

	float3 samplePos = rayStart;

	float project = ( _ProjectionParams.z * _ProjectionParams.y) / (_ProjectionParams.y - _ProjectionParams.z); 
	float mask = 0.0;

	float oldDepth = samplePos.z;
	float oldDelta = 0.0;
	float3 oldSamplePos = samplePos;

	UNITY_LOOP
	for (int i = 0;  i < NumSteps; i++)
	{
		float depth = GetDepth (tex, samplePos.xy);
		float delta = samplePos.z - depth;
		//float thickness = dirProject.z / depth;

		if (0.0 < delta)
		{
				if(delta /*< thickness*/)
				{
					mask = 1.0;
					break;
					//samplePos = samplePos;
				}
				/*if(depth - oldDepth > thickness)
				{
					float blend = (oldDelta - delta) / max(oldDelta, delta) * 0.5 + 0.5;
					samplePos = lerp(oldSamplePos, samplePos, blend);
					mask = lerp(0.0, 1.0, blend);
				}*/
		}
		else
		{
			oldDelta = -delta;
			oldSamplePos = samplePos;
		}
		oldDepth = depth; 
		samplePos += rayDir * stepSize;
	}
	
	return float4(samplePos, mask);
}

// Utility function to get a vector perpendicular to an input vector 
//    (from "Efficient Construction of Perpendicular Vectors Without Branching")
float3 getPerpendicularVector(float3 u)
{
	float3 a = abs(u);
	uint xm = ((a.x - a.y) < 0 && (a.x - a.z) < 0) ? 1 : 0;
	uint ym = (a.y - a.z) < 0 ? (1 ^ xm) : 0;
	uint zm = 1 ^ (xm | ym);
	return cross(u, float3(xm, ym, zm));
}

// Get a cosine-weighted random vector centered around a specified normal direction.
float3 GetCosHemisphereSample(float rand1, float rand2, float3 hitNorm)
{
	// Get 2 random numbers to select our sample with
	float2 randVal = float2(rand1, rand2);

	// Cosine weighted hemisphere sample from RNG
	float3 bitangent = getPerpendicularVector(hitNorm);
	float3 tangent = cross(bitangent, hitNorm);
	float r = sqrt(randVal.x);
	float phi = 2.0f * 3.14159265f * randVal.y;

	// Get our cosine-weighted hemisphere lobe sample direction
	return tangent * (r * cos(phi).x) + bitangent * (r * sin(phi)) + hitNorm.xyz * sqrt(max(0.0, 1.0f - randVal.x));
}

