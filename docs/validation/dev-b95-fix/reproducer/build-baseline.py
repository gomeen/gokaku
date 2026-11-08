from pathlib import Path
import subprocess
root=Path.cwd();folder=root/'.build/windows-composition-lifecycle/x64'
s=(root/'windows/GogakuTsf/src/text_service.cpp').read_text();start=s.index('STDMETHODIMP TextService::OnCompositionTerminated(')
s=s[:start]+'''STDMETHODIMP TextService::OnCompositionTerminated(TfEditCookie,ITfComposition *composition){
    if(editing_)return S_OK;
    if(composition_&&sameObject(composition_,composition)){composition_->Release();composition_=nullptr;if(anchor_){anchor_->Release();anchor_=nullptr;}window_.hide();opened_=false;}
    return S_OK;
}
'''
for header in ['text_service.h','native_edit_safety.h']:
 s=s.replace('#include "'+header+'"', '#include "'+str(root/'windows/GogakuTsf/src'/header)+'"')
source=folder/'b94-text_service.cpp';source.write_text(s)
cxx='x86_64-w64-mingw32-g++';target=folder/'b94-text_service.o'
subprocess.run([cxx,'-std=c++20','-O2','-DNOMINMAX','-DUNICODE','-D_UNICODE','-D_WIN32_WINNT=0x0A00','-DGOGAKU_CHANNEL="composition-lifecycle-test"','-DGOGAKU_SETTINGS_CONTRACT_STATIC','-c',str(source),'-o',str(target)],check=True)
objects=[p for p in folder.glob('*.o') if p.name not in ['text_service.o','b94-text_service.o']]
libs=['user32','gdi32','ole32','oleaut32','uuid','advapi32','shell32','bcrypt','crypt32','d2d1','dwrite','windowscodecs','msimg32']
subprocess.run([cxx,'-static','-o',str(folder/'B94CompositionLifecycleTest.exe'),*[str(p) for p in objects],str(target),*['-l'+n for n in libs]],check=True)
