// Exercises the production RpcClient against a delayed, isolated fake broker.
// Build with -DGOGAKU_CHANNEL=\"rpc-startup-test\". Place copies of this binary
// as bin/x64/RpcStartupTest.exe and bin/x64/GogakuAgent.exe in an empty fixture.
// No product pipe, user text, settings, credentials or frequency data is used.
#include "../windows/GogakuWindows/platform.h"
#include <tlhelp32.h>
#include <fstream>
#include <stdexcept>
#include <algorithm>
using gw::Json;
namespace {
void require(bool value,const char *message){if(!value)throw std::runtime_error(message);}
void stopFixture(){
    auto expected=gw::installRoot()/L"bin/x64/GogakuAgent.exe";
    HANDLE snapshot=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);
    PROCESSENTRY32W entry{sizeof(entry)};
    if(snapshot!=INVALID_HANDLE_VALUE&&Process32FirstW(snapshot,&entry))do{
        HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION|PROCESS_TERMINATE|SYNCHRONIZE,FALSE,entry.th32ProcessID);
        if(!process)continue;
        wchar_t path[32768]{};DWORD length=32768;
        if(QueryFullProcessImageNameW(process,0,path,&length)&&_wcsicmp(path,expected.c_str())==0){TerminateProcess(process,0);WaitForSingleObject(process,2000);}
        CloseHandle(process);
    }while(Process32NextW(snapshot,&entry));
    if(snapshot!=INVALID_HANDLE_VALUE)CloseHandle(snapshot);
}
int server(){
    wchar_t delay[20]{};GetEnvironmentVariableW(L"GOGAKU_RPC_TEST_DELAY_MS",delay,20);
    Sleep((DWORD)_wtoi(delay));
    HANDLE pipe=CreateNamedPipeW(gw::pipeName().c_str(),PIPE_ACCESS_DUPLEX|FILE_FLAG_OVERLAPPED|FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE|PIPE_READMODE_BYTE|PIPE_WAIT|PIPE_REJECT_REMOTE_CLIENTS,1,65536,65536,0,nullptr);
    if(pipe==INVALID_HANDLE_VALUE)return 2;
    OVERLAPPED op{};op.hEvent=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    BOOL connected=ConnectNamedPipe(pipe,&op);DWORD error=GetLastError();
    if(!connected&&error==ERROR_IO_PENDING){DWORD done=0;connected=WaitForSingleObject(op.hEvent,5000)==WAIT_OBJECT_0&&GetOverlappedResult(pipe,&op,&done,FALSE);}
    else if(!connected&&error==ERROR_PIPE_CONNECTED)connected=TRUE;
    if(!connected){CancelIoEx(pipe,nullptr);CloseHandle(op.hEvent);CloseHandle(pipe);return 3;}
    CloseHandle(op.hEvent);
    for(;;){
        Json request;if(!gw::readMessage(pipe,request,3000))break;
        Json response={{"v",gw::ProtocolVersion},{"id",request.value("id",uint64_t(0))},{"ok",true},{"pid",GetCurrentProcessId()}};
        if(!gw::writeMessage(pipe,response,1000)||request.value("op",std::string())=="exit")break;
    }
    FlushFileBuffers(pipe);DisconnectNamedPipe(pipe);CloseHandle(pipe);return 0;
}
void finish(gw::RpcClient &client){
    Json response;require(client.call({{"op","exit"}},response,1000),"fixture exit response missing");
    HANDLE process=OpenProcess(SYNCHRONIZE,FALSE,response.value("pid",0u));
    client.close();if(process){WaitForSingleObject(process,2000);CloseHandle(process);}
}
}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int){
    if(gw::modulePath().filename()==L"GogakuAgent.exe")return server();
    Json result={{"ok",false},{"checks",Json::array()},{"screenshots",Json::array()}};
    try{
        require(gw::channel()=="rpc-startup-test","requires isolated test channel");
        stopFixture();SetEnvironmentVariableW(L"GOGAKU_RPC_TEST_DELAY_MS",L"600");
        {
            gw::RpcClient client;auto start=GetTickCount64();
            bool connected=client.connect(nullptr,5000);auto elapsed=GetTickCount64()-start;
            result["checks"].push_back({{"name","activation_waits_for_cold_broker"},{"passed",connected&&elapsed>=500&&elapsed<6500},{"milliseconds",elapsed}});
            require(connected,"cold activation returned before broker handshake");finish(client);
        }
        Sleep(2100); // Production launch throttling is per host process.
        {
            SetEnvironmentVariableW(L"GOGAKU_RPC_TEST_DELAY_MS",L"3000");
            gw::RpcClient client;auto start=GetTickCount64();bool connected=client.connect();auto elapsed=GetTickCount64()-start;
            result["checks"].push_back({{"name","key_path_does_not_wait_for_startup"},{"passed",!connected&&elapsed<2000},{"milliseconds",elapsed}});
            require(!connected&&elapsed<2000,"key path waited for broker startup");
            start=GetTickCount64();connected=client.connect(nullptr,120);elapsed=GetTickCount64()-start;
            result["checks"].push_back({{"name","startup_wait_has_deadline"},{"passed",!connected&&elapsed>=100&&elapsed<500},{"milliseconds",elapsed}});
            require(!connected&&elapsed>=100&&elapsed<500,"startup deadline not respected");
            require(client.connect(nullptr,5000),"broker unavailable after timeout");finish(client);
        }
        result["ok"]=std::all_of(result["checks"].begin(),result["checks"].end(),[](const Json &c){return c.value("passed",false);});
    }catch(const std::exception &e){result["error"]=e.what();}
    stopFixture();
    std::ofstream(gw::installRoot().parent_path()/L"result.json")<<result.dump(2)<<"\n";
    return result.value("ok",false)?0:1;
}
