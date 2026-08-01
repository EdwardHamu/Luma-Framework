#define GAME_DEMO 1

#define ENABLE_NGX 1

#define ENABLE_FIDELITY_SK 0
#define GEOMETRY_SHADER_SUPPORT 0

#include "..\..\Core\core.hpp"

struct DemoGameDeviceData final : public GameDeviceData
{
};

class DemoGame final : public Game
{
   static DemoGameDeviceData& GetGameDeviceData(DeviceData& device_data)
   {
      return *static_cast<DemoGameDeviceData*>(device_data.game);
   }

public:
   void OnInit(bool async) override
   {
      luma_settings_cbuffer_index = 13;
      luma_data_cbuffer_index = 12;
   }

   void OnCreateDevice(ID3D11Device* native_device, DeviceData& device_data) override
   {
      device_data.game = new DemoGameDeviceData;
   }

   DrawOrDispatchOverrideType OnDrawOrDispatch(ID3D11Device* native_device, ID3D11DeviceContext* native_device_context, CommandListData& cmd_list_data, DeviceData& device_data, reshade::api::shader_stage stages, const ShaderHashesList<OneShaderPerPipeline>& original_shader_hashes, bool is_custom_pass, bool& updated_cbuffers, std::function<void()>* original_draw_dispatch_func) override
   {
      auto& game_device_data = GetGameDeviceData(device_data);

      return DrawOrDispatchOverrideType::None; // Don't cancel the original draw call
   }

   void OnPresent(ID3D11Device* native_device, DeviceData& device_data) override
   {
   }

   void PrintImGuiAbout() override
   {
      ImGui::Text("Demo Luma mod - placeholder project", "");
   }
};

BOOL APIENTRY DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID lpReserved)
{
   if (ul_reason_for_call == DLL_PROCESS_ATTACH)
   {
      const char* project_name = PROJECT_NAME;
      const char* cleared_project_name = (project_name[0] == '_') ? (project_name + 1) : project_name; // Remove the potential "_" at the beginning

      uint32_t mod_version = 1;
      Globals::SetGlobals(cleared_project_name, "Demo Luma mod", "https://github.com/Filoppi/Luma-Framework/", mod_version);

      game = new DemoGame();
   }

   CoreMain(hModule, ul_reason_for_call, lpReserved);

   return TRUE;
}
