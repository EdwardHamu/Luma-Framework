#include "..\..\Core\core.hpp"
#include "common.hpp"

DXGI_FORMAT ResolveGBFRColorViewFormat(DXGI_FORMAT format)
{
   switch (format)
   {
   case DXGI_FORMAT_R32G32B32A32_TYPELESS:
      return DXGI_FORMAT_R32G32B32A32_FLOAT;
   case DXGI_FORMAT_R16G16B16A16_TYPELESS:
      return DXGI_FORMAT_R16G16B16A16_FLOAT;
   case DXGI_FORMAT_R10G10B10A2_TYPELESS:
      return DXGI_FORMAT_R10G10B10A2_UNORM;
   case DXGI_FORMAT_R8G8B8A8_TYPELESS:
      return DXGI_FORMAT_R8G8B8A8_UNORM;
   case DXGI_FORMAT_B8G8R8A8_TYPELESS:
      return DXGI_FORMAT_B8G8R8A8_UNORM;
   case DXGI_FORMAT_B8G8R8X8_TYPELESS:
      return DXGI_FORMAT_B8G8R8X8_UNORM;
   default:
      return format;
   }
}

bool CreateOrRecreateTextureIfNeeded(GameDeviceDataGBFR& game_device_data, ID3D11Device* native_device, D3D11_TEXTURE2D_DESC desc, ComPtr<ID3D11Texture2D>& texture)
{
   bool needs_creation = false;

   if (texture.get() == nullptr)
   {
      needs_creation = true;
   }
   else
   {
      D3D11_TEXTURE2D_DESC existing_desc;
      texture->GetDesc(&existing_desc);
      if (existing_desc.Width != desc.Width ||
          existing_desc.Height != desc.Height ||
          existing_desc.Format != desc.Format ||
          (existing_desc.BindFlags & desc.BindFlags) != desc.BindFlags)
      {
         needs_creation = true;
      }
   }

   if (needs_creation)
   {
      texture = nullptr;
      HRESULT hr = native_device->CreateTexture2D(&desc, nullptr, texture.put());
      if (FAILED(hr) || texture.get() == nullptr)
         ASSERT_ONCE_MSG(false, "Failed to create texture");
   }
   return needs_creation;
}

bool CreateOrRecreateTextureIfNeeded(GameDeviceDataGBFR& game_device_data, ID3D11Device* native_device, D3D11_TEXTURE2D_DESC desc, ComPtr<ID3D11Texture2D>& texture, ComPtr<ID3D11ShaderResourceView>& srv)
{
   if (CreateOrRecreateTextureIfNeeded(game_device_data, native_device, desc, texture))
   {
      srv = nullptr;
      D3D11_SHADER_RESOURCE_VIEW_DESC srv_desc = {};
      srv_desc.Format = ResolveGBFRColorViewFormat(desc.Format);
      srv_desc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
      srv_desc.Texture2D.MipLevels = 1;
      srv_desc.Texture2D.MostDetailedMip = 0;
      HRESULT hr = native_device->CreateShaderResourceView(texture.get(), &srv_desc, srv.put());
      if (FAILED(hr) || srv.get() == nullptr)
         ASSERT_ONCE_MSG(false, "Failed to create shader resource view");

      return true;
   }

   return false;
}

bool CreateOrRecreateTextureIfNeeded(GameDeviceDataGBFR& game_device_data, ID3D11Device* native_device, D3D11_TEXTURE2D_DESC desc, ComPtr<ID3D11Texture2D>& texture, ComPtr<ID3D11ShaderResourceView>& srv, ComPtr<ID3D11RenderTargetView>& rtv)
{
   if (CreateOrRecreateTextureIfNeeded(game_device_data, native_device, desc, texture))
   {
      srv = nullptr;
      D3D11_SHADER_RESOURCE_VIEW_DESC srv_desc = {};
      srv_desc.Format = ResolveGBFRColorViewFormat(desc.Format);
      srv_desc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
      srv_desc.Texture2D.MipLevels = 1;
      srv_desc.Texture2D.MostDetailedMip = 0;
      HRESULT hr = native_device->CreateShaderResourceView(texture.get(), &srv_desc, srv.put());
      if (FAILED(hr) || srv.get() == nullptr)
         ASSERT_ONCE_MSG(false, "Failed to create shader resource view");

      rtv = nullptr;
      D3D11_RENDER_TARGET_VIEW_DESC rtv_desc = {};
      rtv_desc.Format = ResolveGBFRColorViewFormat(desc.Format);
      rtv_desc.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2D;
      rtv_desc.Texture2D.MipSlice = 0;
      hr = native_device->CreateRenderTargetView(texture.get(), &rtv_desc, rtv.put());
      if (FAILED(hr) || rtv.get() == nullptr)
         ASSERT_ONCE_MSG(false, "Failed to create render target view");

      return true;
   }

   return false;
}

bool IsTonemapAfterTAAEnabled(bool require_taa_running)
{
   // Native SDR tonemaps before TAA. Replaying tonemap after its R8 output
   // would process an already mapped and clamped image a second time.
   if (cb_luma_global_settings.DisplayMode == DisplayModeType::SDR)
      return false;

   const bool tonemap_enabled = *GetShaderDefineData(char_ptr_crc32("TONEMAP_AFTER_TAA")).compiled_data.GetValue() != '0';
   return tonemap_enabled && (!require_taa_running || IsTAARunningThisFrame());
}

void RefreshFrameJitterForPostProcess(GameDeviceDataGBFR& game_device_data)
{
   game_device_data.prev_table_jitter = game_device_data.table_jitter;
#ifdef PATCH_JITTER_TABLE_INIT
   TryReadTableJitterFromCounter(game_device_data.table_jitter);
#else
   TryReadTableJitter(game_device_data.table_jitter);
#endif
#if TEST || DEVELOPMENT
   game_device_data.prev_jitter = game_device_data.jitter;
   TryReadCameraJitter(game_device_data.jitter);
#endif
}

ID3D11ShaderResourceView* GetPostAAColorInputSRV(const DeviceData& device_data, const GameDeviceDataGBFR& game_device_data)
{
   const bool use_sr_input = device_data.sr_type != SR::Type::None && !device_data.sr_suppressed;
   return use_sr_input ? game_device_data.sr_output_color_srv.get()
                       : game_device_data.taa_temp_output_srv.get();
}

bool CanDrawNativeUIEncodePass(ID3D11ShaderResourceView* input_color_srv, const GameDeviceDataGBFR& game_device_data)
{
   return input_color_srv != nullptr && game_device_data.taa_output_texture_rtv.get() != nullptr;
}
