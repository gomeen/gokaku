#include <windows.h>
/* Both payload EXEs exit successfully without reading arguments or writing state. */
int WINAPI WinMain(HINSTANCE instance, HINSTANCE previous, LPSTR command, int show) {
    (void)instance; (void)previous; (void)command; (void)show; return 0;
}
