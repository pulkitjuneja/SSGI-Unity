﻿Shader "Effects/SSGI" 
{
	Properties 
	{
		_MainTex ("Base (RGB)", 2D) = "black" {}
	}
	
	CGINCLUDE
	
	#include "UnityCG.cginc"
	#include "UnityPBSLighting.cginc"
    #include "UnityStandardBRDF.cginc"
    #include "UnityStandardUtils.cginc"

	#include "Utils.cginc"
	#include "NoiseLib.cginc"

	struct VertexInput 
	{
		float4 vertex : POSITION;
		float2 texcoord : TEXCOORD0;
	};

	struct VertexOutput
	{
		float2 uv : TEXCOORD0;
		float4 vertex : SV_POSITION;
	};

	VertexOutput vert( VertexInput v ) 
	{
		VertexOutput o;
		o.vertex = UnityObjectToClipPos(v.vertex);
		o.uv = v.texcoord;
		return o;
	}

	void rayCast ( VertexOutput i, 	out half4 outRayCast : SV_Target0, out half4 outRayCastMask : SV_Target1) 
	{	
		float2 uv = i.uv;
		int2 pos = uv /* _RayCastSize.xy*/;

		float4 worldNormal = GetNormal (uv);
		float3 viewNormal = GetViewNormal (worldNormal);
		float4 specular = tex2D(_CameraGBufferTexture1, uv);
		float roughness = GetRoughness (specular.a);

		float depth = GetDepth(_CameraDepthTexture, uv);
		float3 screenPos = float3(uv.xy * 2 - 1, depth);

		float3 worldPos = GetWorlPos(screenPos);
		float3 viewDir = normalize(worldPos - _WorldSpaceCameraPos);

		float3 viewPos = /*mul(_WorldToCameraMatrix, float4(worldPos, 1.0))*/ GetViewPos(screenPos);

		float2 jitter = tex2Dlod(_Noise, float4((uv + _JitterSizeAndOffset.zw) * _RayCastSize.xy / _NoiseSize.xy, 0, -255)); // Blue noise generated by https://github.com/bartwronski/BlueNoiseGenerator/;

		float2 Xi = jitter;

		Xi.y = lerp(Xi.y, 0.0, _BRDFBias);

		float4 H = TangentToWorld(worldNormal, ImportanceSampleGGX(Xi, roughness));
		float3 dir = reflect(viewDir, H.xyz);
		dir = normalize(mul((float3x3)_WorldToCameraMatrix, dir));

		jitter += 0.5f;

		float stepSize = (1.0 / (float)_NumSteps);
		stepSize = stepSize * (jitter.x + jitter.y) + stepSize;

		float2 rayTraceHit = 0.0;
		float rayTraceZ = 0.0;
		float rayPDF = 0.0;
		float rayMask = 0.0;
		float4 rayTrace = RayMarch(_CameraDepthTexture, _ProjectionMatrix, dir, _NumSteps, viewPos, screenPos, uv, stepSize, 1.0);

		rayTraceHit = rayTrace.xy;
		rayTraceZ = rayTrace.z;
		rayPDF = H.w;
		rayMask = rayTrace.w;

		outRayCast = float4(float3(rayTraceHit, rayTraceZ), rayPDF);
		outRayCastMask = rayMask;
	}

	float4 RayCastDiffuse(VertexOutput i):SV_Target
	{
		float2 uv = i.uv;
		int2 pos = uv /* _RayCastSize.xy*/;


		float depth = GetDepth(_CameraDepthTexture, uv);
		float3 screenPos = float3(uv.xy * 2 - 1, depth);

		float3 worldPos = GetWorlPos(screenPos);
		float3 viewDir = normalize(tex2D(_MainTex, uv).xyz);


		float3 viewPos = GetViewPos(screenPos);

		float2 jitter = tex2Dlod(_Noise, float4((uv) * _ScreenSize.xy / _NoiseSize.xy, 0, -255)); // Blue noise generated by https://github.com/bartwronski/BlueNoiseGenerator/;

		float3 dir = normalize(mul((float3x3)_WorldToCameraMatrix, viewDir));

		jitter += 0.5f;

		float stepSize = (1.0 / (float)_NumSteps);
		stepSize = stepSize * (jitter.x + jitter.y) + stepSize;

		float2 rayTraceHit = 0.0;
		float rayTraceZ = 0.0;
		float rayPDF = 0.0;
		float rayMask = 0.0;
		float4 rayTrace = RayMarch(_CameraDepthTexture, _ProjectionMatrix, dir, _NumSteps, viewPos, screenPos, uv, stepSize, 1.0);

		float2 hitUV = rayTrace.xy;
		rayMask = rayTrace.w;
		float4 sampleColor = float4(0.0, 0.0, 0.0, 1.0);
		float3 cubemap = GetCubeMap(hitUV);
		sampleColor.rgb = tex2Dlod(_SourceColor, float4(hitUV, 0.0, 0)).rgb*rayMask;

		return sampleColor;
	}

	float4 reproject( VertexOutput i ) : SV_Target
	{	 
		float2 uv = i.uv;
		float depth = GetDepth(_CameraDepthTexture, uv);
		float3 screenPos = float3(uv.xy * 2 - 1, depth);
		float2 velocity = tex2D(_CameraMotionVectorsTexture, uv);
		float2 prevUV = uv - velocity;
		float4 sceneColor = tex2D(_MainTex,  prevUV);

		return sceneColor;
	}

    float4 resolve ( VertexOutput i ) : SV_Target
	{
		float2 uv = i.uv;
		int2 pos = uv * _ScreenSize.xy;

		float4 worldNormal = GetNormal (uv);
		float3 viewNormal = normalize(mul((float3x3)_WorldToCameraMatrix, worldNormal.rgb));
		float4 specular = tex2D(_CameraGBufferTexture1, uv);
		float roughness = GetRoughness (specular.a);

		float depth = GetDepth(_CameraDepthTexture, uv);
		float3 screenPos = float3(uv.xy * 2 - 1, depth);
		float3 worldPos = GetWorlPos(screenPos);
		float3 viewPos = GetViewPos(screenPos);
		float3 viewDir = normalize(worldPos - _WorldSpaceCameraPos);

		// Blue noise generated by https://github.com/bartwronski/BlueNoiseGenerator/
		float2 blueNoise = tex2D(_Noise, (uv + _JitterSizeAndOffset.zw) * _ScreenSize.xy / _NoiseSize.xy) * 2.0 - 1.0;
		float2x2 offsetRotationMatrix = float2x2(blueNoise.x, blueNoise.y, -blueNoise.y, blueNoise.x);

		int NumResolve = 1;
		if(_RayReuse == 1)
			NumResolve = 4;

		float NdotV = saturate(dot(worldNormal, -viewDir));
		// float coneTangent = lerp(0.0, roughness * (1.0 - _BRDFBias), NdotV * sqrt(roughness));
		// float maxMipLevel = (float)_MaxMipMap - 1.0;

		float4 result = 0.0;
        for(int i = 0; i < NumResolve; i++)
        {
			float2 offsetUV = offset[i] * (1.0 / _ResolveSize.xy);
			offsetUV =  mul(offsetRotationMatrix, offsetUV);
			float2 neighborUv = uv + offsetUV;

            float4 hitPacked = tex2Dlod(_RayCast, float4(neighborUv, 0.0, 0.0));
            float2 hitUv = hitPacked.xy;
            float hitZ = hitPacked.z;
            float hitPDF = hitPacked.w;
			float hitMask = tex2Dlod(_RayCastMask, float4(neighborUv, 0.0, 0.0)).r;

			float3 hitViewPos = GetViewPos(float3(hitUv.xy *2 - 1, hitZ));
			float weight = 1.0;

			// float intersectionCircleRadius = coneTangent * length(hitUv - uv);
			// float mip = clamp(log2(intersectionCircleRadius * max(_ResolveSize.x, _ResolveSize.y)), 0.0, maxMipLevel);

			float4 sampleColor = float4(0.0,0.0,0.0,1.0);
			sampleColor.rgb = tex2Dlod(_MainTex, float4(hitUv, 0.0, 0)).rgb;
			sampleColor.a = RayAttenBorder (hitUv, _EdgeFactor) * hitMask;
            sampleColor.rgb /= 1 + Luminance(sampleColor.rgb);

            result += sampleColor;
        }
        result /= NumResolve;
        result.rgb /= 1 - Luminance(result.rgb);
    	return  max(1e-5, result);
	}

    void temporal (VertexOutput i, out half4 reflection : SV_Target)
	{	
		float2 uv = i.uv;
		float2 velocity = tex2D(_CameraMotionVectorsTexture, uv);
		float2 prevUV = uv - velocity;

		float4 current = tex2D(_MainTex, uv);
		float4 previous = tex2D(_PreviousBuffer, prevUV);

		float2 du = float2(1.0 / _ScreenSize.x, 0.0);
		float2 dv = float2(0.0, 1.0 / _ScreenSize.y);

		float4 currentTopLeft = tex2D(_MainTex, uv.xy - dv - du);
		float4 currentTopCenter = tex2D(_MainTex, uv.xy - dv);
		float4 currentTopRight = tex2D(_MainTex, uv.xy - dv + du);
		float4 currentMiddleLeft = tex2D(_MainTex, uv.xy - du);
		float4 currentMiddleCenter = tex2D(_MainTex, uv.xy);
		float4 currentMiddleRight = tex2D(_MainTex, uv.xy + du);
		float4 currentBottomLeft = tex2D(_MainTex, uv.xy + dv - du);
		float4 currentBottomCenter = tex2D(_MainTex, uv.xy + dv);
		float4 currentBottomRight = tex2D(_MainTex, uv.xy + dv + du);

		float4 currentMin = min(currentTopLeft, min(currentTopCenter, min(currentTopRight, min(currentMiddleLeft, min(currentMiddleCenter, min(currentMiddleRight, min(currentBottomLeft, min(currentBottomCenter, currentBottomRight))))))));
		float4 currentMax = max(currentTopLeft, max(currentTopCenter, max(currentTopRight, max(currentMiddleLeft, max(currentMiddleCenter, max(currentMiddleRight, max(currentBottomLeft, max(currentBottomCenter, currentBottomRight))))))));

		float scale = _TScale;

		float4 center = (currentMin + currentMax) * 0.5f;
		currentMin = (currentMin - center) * scale + center;
		currentMax = (currentMax - center) * scale + center;

		previous = clamp(previous, currentMin, currentMax);
    	reflection = lerp(current, previous, saturate(_TResponse *  (1 - length(velocity) * 8)) );
	}

	float4 combine( VertexOutput i ) : SV_Target
	{	 
		float2 uv = i.uv;
		float depth = GetDepth(_CameraDepthTexture, uv);
		float3 screenPos = float3(uv.xy * 2 - 1, depth);
		float3 worldPos = GetWorlPos(screenPos);

		float4 cubemap = GetCubeMap (uv);
		float4 worldNormal = GetNormal (uv);

		float4 diffuse =  tex2D(_CameraGBufferTexture0, uv);
		float occlusion = diffuse.a;
		float4 specular = tex2D(_CameraGBufferTexture1, uv);
		float roughness = GetRoughness(specular.a);

		float4 sceneColor = tex2D(_MainTex,  uv);
		sceneColor.rgb = max(1e-5, sceneColor.rgb - cubemap.rgb);

		float4 reflection = tex2D(_ReflectionBuffer, uv);
		float4 diffuseIndirectColor = tex2D(_DiffuseReflectionBuffer, uv);
		float3 viewDir = normalize(worldPos - _WorldSpaceCameraPos);
		float mask = reflection.a * reflection.a /* fade*/;
		
		float oneMinusReflectivity;
		diffuse.rgb = EnergyConservationBetweenDiffuseAndSpecular(diffuse, specular.rgb, oneMinusReflectivity);
		
 		UnityLight light;	
        light.color = 0;
        light.dir = 0;
        light.ndotl = 0;
		
        UnityIndirect ind;
        ind.diffuse = 0;
        ind.specular = reflection;

		reflection.rgb = UNITY_BRDF_PBS (diffuse.rgb, specular.rgb, oneMinusReflectivity, 1-roughness, worldNormal, -viewDir, light, ind).rgb;
		reflection.rgb *= occlusion;
		
		diffuseIndirectColor.rgb *= diffuse.rgb;

		if (_EnableIndirectLighting)
		{
			//diffuseIndirectColor.rgb = EnergyConservationBetweenDiffuseAndSpecular(diffuseIndirectColor.rgb, reflection.rgb, oneMinusReflectivity);
			sceneColor += lerp(cubemap, reflection, mask);
			sceneColor.rgb += diffuseIndirectColor.rgb;// +reflection.rgb;
		}

		return sceneColor;// float4(cubemap, 1.0);
	}

	float4 CreateCustomNormals(VertexOutput i) : SV_Target
	{
		float2 uv = i.uv;
		int2 pos = uv * _ScreenSize.xy;

		float4 worldNormal = GetNormal(uv);
		float normalLength = length(worldNormal);
		if(length(tex2D(_CameraGBufferTexture2, uv))==0)
		{
			return float4(0,0,0,1);
		}
		// Blue noise generated by https://github.com/bartwronski/BlueNoiseGenerator/
		float noise = IGN(pos.x,pos.y, _FrameCount);
		float noise1 = IGN(pos.x,pos.y, _FrameCount+1);
		float2 blueNoise = tex2D(_Noise, (uv+_JitterSizeAndOffset.zw)*_ScreenSize.xy / _NoiseSize.xy) * 2.0 - 1.0;
		float3 stochasticNormal = GetCosHemisphereSample(noise, noise1, worldNormal);

		return normalize(float4(stochasticNormal,1));
	}

	ENDCG 
	
	SubShader 
	{
		ZTest Always Cull Off ZWrite Off

		//0
		Pass 
		{
			CGPROGRAM
			#pragma target 3.0

			#ifdef SHADER_API_OPENGL
       			#pragma glsl
    		#endif

			#pragma exclude_renderers nomrt xbox360 ps3 xbox360 ps3

			#pragma vertex vert
			#pragma fragment reproject
			ENDCG
		}
		//1
		Pass 
		{
			CGPROGRAM
			#pragma target 3.0

			#ifdef SHADER_API_OPENGL
       			#pragma glsl
    		#endif

			#pragma exclude_renderers nomrt xbox360 ps3 xbox360 ps3

			#pragma vertex vert
			#pragma fragment rayCast
			ENDCG
		}
		//2
        Pass 
        {
        	CGPROGRAM
        	#pragma target 3.0

        	#ifdef SHADER_API_OPENGL
        		#pragma glsl
        	#endif

        	#pragma exclude_renderers nomrt xbox360 ps3 xbox360 ps3

        	#pragma vertex vert
        	#pragma fragment resolve
        	ENDCG
        }
		//3
		Pass 
		{
			CGPROGRAM
			#pragma target 3.0

			#ifdef SHADER_API_OPENGL
       			#pragma glsl
    		#endif

			#pragma exclude_renderers nomrt xbox360 ps3 xbox360 ps3

			#pragma vertex vert
			#pragma fragment temporal
			ENDCG
		}
		//4
		Pass 
		{
			CGPROGRAM
			#pragma target 3.0

			#ifdef SHADER_API_OPENGL
       			#pragma glsl
    		#endif

			#pragma exclude_renderers nomrt xbox360 ps3 xbox360 ps3

			#pragma vertex vert
			#pragma fragment combine
			ENDCG
		}

		//5
		Pass
		{
			CGPROGRAM
			#pragma target 3.0

			#ifdef SHADER_API_OPENGL
				#pragma glsl
			#endif

			#pragma exclude_renderers nomrt xbox360 ps3 xbox360 ps3

			#pragma vertex vert
			#pragma fragment CreateCustomNormals
			ENDCG
		}

		//6
		Pass
		{
			CGPROGRAM
			#pragma target 3.0

			#ifdef SHADER_API_OPENGL
				#pragma glsl
			#endif

			#pragma exclude_renderers nomrt xbox360 ps3 xbox360 ps3

			#pragma vertex vert
			#pragma fragment RayCastDiffuse
			ENDCG
		}
		// //5
		// Pass 
		// {
		// 	CGPROGRAM
		// 	#pragma target 3.0

		// 	#ifdef SHADER_API_OPENGL
       	// 		#pragma glsl
    	// 	#endif

		// 	#pragma exclude_renderers nomrt xbox360 ps3 xbox360 ps3

		// 	#pragma vertex vert
		// 	#pragma fragment temporal
		// 	ENDCG
		// }
		// //6
		// Pass 
		// {
		// 	CGPROGRAM
		// 	#pragma target 3.0

		// 	#ifdef SHADER_API_OPENGL
       	// 		#pragma glsl
    	// 	#endif

		// 	#pragma exclude_renderers nomrt xbox360 ps3 xbox360 ps3

		// 	#pragma vertex vert
		// 	#pragma fragment mipMapBlur
		// 	ENDCG
		// }
		// //7
		// Pass 
		// {
		// 	CGPROGRAM
		// 	#pragma target 3.0

		// 	#ifdef SHADER_API_OPENGL
       	// 		#pragma glsl
    	// 	#endif

		// 	#pragma exclude_renderers nomrt xbox360 ps3 xbox360 ps3

		// 	#pragma vertex vert
		// 	#pragma fragment debug
		// 	ENDCG
		// }
		// //8
		// Pass 
		// {
		// 	CGPROGRAM
		// 	#pragma target 3.0

		// 	#ifdef SHADER_API_OPENGL
       	// 		#pragma glsl
    	// 	#endif

		// 	#pragma exclude_renderers nomrt xbox360 ps3 xbox360 ps3

		// 	#pragma vertex vert
		// 	#pragma fragment recursive
		// 	ENDCG
		// }
	}
	Fallback Off
}
