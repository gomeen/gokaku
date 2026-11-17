/* 精简模块注册表：只注册 gogaku_freetype 编入的模块。
 * 编入清单见 shared/GogakuCore/CMakeLists.txt 的 gogaku_freetype 源列表。
 * ftinit.c 经 include 路径优先级取本文件（替代出厂数字全量注册表）。 */
FT_USE_MODULE( FT_Module_Class, autofit_module_class )
FT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )
FT_USE_MODULE( FT_Driver_ClassRec, cff_driver_class )
FT_USE_MODULE( FT_Module_Class, psaux_module_class )
FT_USE_MODULE( FT_Module_Class, psnames_module_class )
FT_USE_MODULE( FT_Module_Class, pshinter_module_class )
FT_USE_MODULE( FT_Module_Class, sfnt_module_class )
FT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )
