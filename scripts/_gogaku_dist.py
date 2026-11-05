#!/usr/bin/env python3
"""dist 产物与安装身份的共享约定（双通道/Mac 安装链共用）。

背景（2026-11-06 事故）：输入法身份键（TISInputSourceID／
ComponentInputModeDict 等）写进 dist 包后，仓库内副本被 LaunchServices
周期扫描注册成输入源——同 ID 幽灵遮蔽真身，输入法列表出现多个同名条目
且「键盘布局不可用」；lsregister -u 清掉后数分钟内又被扫回。pkg 安装
沙箱（PKInstallSandboxManager/Scripts）同样被扫描，随包携带的 .app 在
安装结束后留下死路径注册。

约定（永久修复）：
- **dist 产物一律中立**：不携带身份键——被扫描注册也只是普通 App，
  永远不进输入源列表；
- **安装时在目标位置注入身份**（manage-install／pkg postinstall／DMG
  command），随后 ad-hoc 重签；
- 身份键集合与重建逻辑只在本模块，各链路共享，避免漂移。

身份键（8 个）：运行必需键（LSBackgroundOnly／InputMethodServerControllerClass／
InputMethodType／NSPrincipalClass）不属于身份，dist 保留。
"""
import plistlib

# 仅这些键制造「输入源」身份；dist 剥离、安装注入。
TIS_IDENTITY_KEYS = (
    'TISInputSourceID',
    'TISIntendedLanguage',
    'tsInputMethodCharacterRepertoireKey',
    'tsInputMethodLanguageKey',
    'tsInputMethodIconFileKey',
    'TICapsLockLanguageSwitchCapable',
    'TISIconIsTemplate',
    'ComponentInputModeDict',
)


def tis_identity(identifier: str) -> dict:
    """按 bundle identifier 重建完整身份键（与历史 build.py 直写内容逐键一致）。"""
    return {
        'TISInputSourceID': identifier, 'TISIntendedLanguage': 'zh-Hans',
        'tsInputMethodCharacterRepertoireKey': ['Hans'],
        'tsInputMethodLanguageKey': 'zh-Hans',
        'tsInputMethodIconFileKey': 'gogaku-menu.pdf',
        # TIS 从 ComponentInputModeDict 构建可选输入源；缺失时系统设置找不到该输入法。
        # 图标键必须带扩展名且与包内文件一致。只声明 Caps Lock 切换能力。
        'TICapsLockLanguageSwitchCapable': True,
        # 模板图标（对齐青简）：胶囊＋镂空 PDF，深浅色菜单栏与切换器都正确。
        'TISIconIsTemplate': True,
        'ComponentInputModeDict': {
            'tsInputModeListKey': {
                f'{identifier}.Hans': {
                    'TISInputSourceID': f'{identifier}.Hans',
                    'TISIntendedLanguage': 'zh-Hans',
                    'tsInputModeCharacterRepertoireKey': ['Hans'],
                    'tsInputModeDefaultStateKey': True,
                    'tsInputModeIsVisibleKey': True,
                    'tsInputModeMenuIconFileKey': 'gogaku-menu.pdf',
                    'tsInputModeAlternateMenuIconFileKey': 'gogaku-menu.pdf',
                    'tsInputModePaletteIconFileKey': 'gogaku-menu.pdf',
                    'tsInputModePrimaryInScriptKey': True,
                    'tsInputModeScriptKey': 'smUnicodeScript',
                },
            },
            'tsVisibleInputModeOrderedArrayKey': [f'{identifier}.Hans'],
        },
    }


def strip_tis_identity(info: dict) -> dict:
    """返回剥离身份键后的副本（浅拷贝顶层；身份键整体移除）。"""
    out = dict(info)
    for key in TIS_IDENTITY_KEYS:
        out.pop(key, None)
    return out


def apply_tis_identity(info: dict, identifier: str) -> dict:
    """返回注入身份键后的副本（先剥离再注入，幂等）。"""
    out = strip_tis_identity(info)
    out.update(tis_identity(identifier))
    return out


def deterministic_plist_bytes(info: dict) -> bytes:
    """确定性序列化：安装写入与安装前期望哈希必须逐字节一致。"""
    return plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=True)
