/*  RetroArch - A frontend for libretro.
 *  Copyright (C) 2013-2014 - Jason Fetters
 *  Copyright (C) 2011-2017 - Daniel De Matteis
 *
 *  RetroArch is free software: you can redistribute it and/or modify it under the terms
 *  of the GNU General Public License as published by the Free Software Found-
 *  ation, either version 3 of the License, or (at your option) any later version.
 *
 *  RetroArch is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 *  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 *  PURPOSE.  See the GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License along with RetroArch.
 *  If not, see <http://www.gnu.org/licenses/>.
 */

#ifdef HAVE_CONFIG_H
#include "../../config.h"
#endif

#if TARGET_OS_IPHONE
#include <CoreGraphics/CoreGraphics.h>
#else
#include <ApplicationServices/ApplicationServices.h>
#endif
#ifdef OSX
#include <OpenGL/CGLTypes.h>
#include <OpenGL/OpenGL.h>
#include <AppKit/NSScreen.h>
#include <AppKit/NSOpenGL.h>
#elif defined(HAVE_COCOATOUCH)
#include <GLKit/GLKit.h>
#endif

#include <retro_assert.h>
#include <retro_timers.h>
#include <compat/apple_compat.h>
#include <string/stdstring.h>

#include "../../ui/drivers/ui_cocoa.h"
#include "../../ui/drivers/cocoa/cocoa_common.h"
#include "../../ui/drivers/cocoa/apple_platform.h"
#include "../../configuration.h"
#include "../../retroarch.h"
#include "../../verbosity.h"
#ifdef HAVE_VULKAN
#include "../common/vulkan_common.h"
#endif
#ifdef HAVE_METAL
#include "../common/metal_common.h"
#endif

#if defined(HAVE_COCOATOUCH)
#define GLContextClass  EAGLContext
#define GLFrameworkID   CFSTR("com.apple.opengles")
#else
#define GLContextClass  NSOpenGLContext
#define GLFrameworkID   CFSTR("com.apple.opengl")
#endif

typedef struct cocoa_ctx_data
{
#ifdef HAVE_VULKAN
   gfx_ctx_vulkan_data_t vk;
   int swap_interval;
#endif
#ifndef OSX
   int fast_forward_skips;
#endif
   unsigned width;
   unsigned height;
#ifndef OSX
   bool is_syncing;
#endif
   bool core_hw_context_enable;
   bool use_hw_ctx;
} cocoa_ctx_data_t;

/* TODO/FIXME - static globals */
static enum gfx_ctx_api cocoagl_api = GFX_CTX_NONE;
static GLContextClass* g_hw_ctx     = NULL;
static GLContextClass* g_context    = NULL;
static unsigned g_minor             = 0;
static unsigned g_major             = 0;
#ifdef OSX
static NSOpenGLPixelFormat* g_format;
#endif
#if defined(HAVE_COCOATOUCH)
static GLKView *glk_view            = NULL;

@interface EAGLContext (OSXCompat) @end
@implementation EAGLContext (OSXCompat)
+ (void)clearCurrentContext { [EAGLContext setCurrentContext:nil];  }
- (void)makeCurrentContext  { [EAGLContext setCurrentContext:self]; }
@end
#else
@interface NSScreen (IOSCompat) @end
@implementation NSScreen (IOSCompat)
- (CGRect)bounds
{
   CGRect cgrect  = NSRectToCGRect(self.frame);
   return CGRectMake(0, 0, CGRectGetWidth(cgrect), CGRectGetHeight(cgrect));
}
- (float) scale  { return 1.0f; }
@end
#endif

static uint32_t cocoa_gl_gfx_ctx_get_flags(void *data)
{
   uint32_t flags                 = 0;
   cocoa_ctx_data_t    *cocoa_ctx = (cocoa_ctx_data_t*)data;

   if (cocoa_ctx->core_hw_context_enable)
      BIT32_SET(flags, GFX_CTX_FLAGS_GL_CORE_CONTEXT);

   switch (cocoagl_api)
   {
      case GFX_CTX_OPENGL_ES_API:
#ifdef HAVE_GLSL
         BIT32_SET(flags, GFX_CTX_FLAGS_SHADERS_GLSL);
#endif
         break;
      case GFX_CTX_OPENGL_API:
         if (string_is_equal(video_driver_get_ident(), "gl1")) { }
         else if (string_is_equal(video_driver_get_ident(), "glcore"))
         {
#if defined(HAVE_SLANG) && defined(HAVE_SPIRV_CROSS)
            BIT32_SET(flags, GFX_CTX_FLAGS_SHADERS_SLANG);
#endif
         }
         else
         {
#ifdef HAVE_GLSL
            BIT32_SET(flags, GFX_CTX_FLAGS_SHADERS_GLSL);
#endif
         }
         break;
      case GFX_CTX_VULKAN_API:
#if defined(HAVE_SLANG) && defined(HAVE_SPIRV_CROSS)
         BIT32_SET(flags, GFX_CTX_FLAGS_SHADERS_SLANG);
#endif
         break;
      default:
         break;
   }

   return flags;
}

static void cocoa_gl_gfx_ctx_set_flags(void *data, uint32_t flags)
{
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)data;

   if (BIT32_GET(flags, GFX_CTX_FLAGS_GL_CORE_CONTEXT))
      cocoa_ctx->core_hw_context_enable = true;
}

#if !defined(OSX)
#if defined(HAVE_COCOATOUCH)
void *glkitview_init(void)
{
   glk_view                      = [GLKView new];
#if TARGET_OS_IOS
   glk_view.multipleTouchEnabled = YES;
#endif
   glk_view.enableSetNeedsDisplay = NO;

   return (BRIDGE void *)((GLKView*)glk_view);
}

void glkitview_bind_fbo(void)
{
   if (g_context)
      [glk_view bindDrawable];
}
#endif
#endif

void cocoa_gl_gfx_ctx_update(void)
{
   switch (cocoagl_api)
   {
      case GFX_CTX_OPENGL_API:
#if defined(HAVE_OPENGL) || defined(HAVE_OPENGLES) || defined(HAVE_OPENGL_CORE)
#ifdef OSX
         [g_context update];
         [g_hw_ctx update];
#endif
#endif
         break;
      default:
         break;
   }
}

static void cocoa_gl_gfx_ctx_destroy(void *data)
{
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)data;

   if (!cocoa_ctx)
      return;

   switch (cocoagl_api)
   {
      case GFX_CTX_OPENGL_API:
      case GFX_CTX_OPENGL_ES_API:
#if defined(HAVE_OPENGL) || defined(HAVE_OPENGLES) || defined(HAVE_OPENGL_CORE)
         [GLContextClass clearCurrentContext];

#ifdef OSX
         [g_context clearDrawable];
         RELEASE(g_context);
         RELEASE(g_format);
         if (g_hw_ctx)
            [g_hw_ctx clearDrawable];
         RELEASE(g_hw_ctx);
#endif
         [GLContextClass clearCurrentContext];
         g_context = nil;
#endif
         break;
      case GFX_CTX_VULKAN_API:
#ifdef HAVE_VULKAN
         vulkan_context_destroy(&cocoa_ctx->vk, cocoa_ctx->vk.vk_surface != VK_NULL_HANDLE);
         if (cocoa_ctx->vk.context.queue_lock)
            slock_free(cocoa_ctx->vk.context.queue_lock);
         memset(&cocoa_ctx->vk, 0, sizeof(cocoa_ctx->vk));
#endif
         break;
      case GFX_CTX_NONE:
      default:
         break;
   }

   free(cocoa_ctx);
}

static enum gfx_ctx_api cocoa_gl_gfx_ctx_get_api(void *data) { return cocoagl_api; }

#ifdef OSX
static bool cocoa_gl_gfx_ctx_get_metrics(
      void *data, enum display_metric_types type,
      float *value)
{
   RAScreen *screen              = (BRIDGE RAScreen*)cocoa_screen_get_chosen();
   NSDictionary *desc            = [screen deviceDescription];
   CGSize  display_physical_size = CGDisplayScreenSize(
         [[desc objectForKey:@"NSScreenNumber"] unsignedIntValue]);

   float   physical_width        = display_physical_size.width;
   float   physical_height       = display_physical_size.height;

   switch (type)
   {
      case DISPLAY_METRIC_MM_WIDTH:
         *value = physical_width;
         break;
      case DISPLAY_METRIC_MM_HEIGHT:
         *value = physical_height;
         break;
      case DISPLAY_METRIC_DPI:
         {
            NSSize disp_pixel_size = [[desc objectForKey:NSDeviceSize] sizeValue];
            float dispwidth = disp_pixel_size.width;
            float   scale   = cocoa_screen_get_backing_scale_factor();
            float   dpi     = (dispwidth / physical_width) * 25.4f * scale;
            *value          = dpi;
         }
         break;
      case DISPLAY_METRIC_NONE:
      default:
         *value = 0;
         return false;
   }

   return true;
}
#else
static bool cocoa_gl_gfx_ctx_get_metrics(
      void *data, enum display_metric_types type,
      float *value)
{
   RAScreen *screen              = (BRIDGE RAScreen*)cocoa_screen_get_chosen();
   float   scale                 = cocoa_screen_get_native_scale();
   CGRect  screen_rect           = [screen bounds];
   float   physical_width        = screen_rect.size.width  * scale;
   float   physical_height       = screen_rect.size.height * scale;
   float   dpi                   = 160                     * scale;
   NSInteger idiom_type          = UI_USER_INTERFACE_IDIOM();

   switch (idiom_type)
   {
      case -1: /* UIUserInterfaceIdiomUnspecified */
         /* TODO */
         break;
      case UIUserInterfaceIdiomPad:
         dpi = 132 * scale;
         break;
      case UIUserInterfaceIdiomPhone:
         {
            CGFloat maxSize = fmaxf(physical_width, physical_height);
            /* Larger iPhones: iPhone Plus, X, XR, XS, XS Max, 11, 11 Pro Max */
            if (maxSize >= 2208.0)
               dpi = 81 * scale;
            else
               dpi = 163 * scale;
         }
         break;
      case UIUserInterfaceIdiomTV:
      case UIUserInterfaceIdiomCarPlay:
         /* TODO */
         break;
   }

   switch (type)
   {
      case DISPLAY_METRIC_MM_WIDTH:
         *value = physical_width;
         break;
      case DISPLAY_METRIC_MM_HEIGHT:
         *value = physical_height;
         break;
      case DISPLAY_METRIC_DPI:
         *value = dpi;
         break;
      case DISPLAY_METRIC_NONE:
      default:
         *value = 0;
         return false;
   }

   return true;
}
#endif

static bool cocoa_gl_gfx_ctx_suppress_screensaver(void *data, bool enable) { return false; }

static void cocoa_gl_gfx_ctx_input_driver(void *data,
      const char *name,
      input_driver_t **input, void **input_data)
{
   *input      = NULL;
   *input_data = NULL;
}

#if MAC_OS_X_VERSION_10_7 && defined(OSX)
/* NOTE: convertRectToBacking only available on MacOS X 10.7 and up.
 * Therefore, make specialized version of this function instead of
 * going through a selector for every call. */
static void cocoa_gl_gfx_ctx_get_video_size_osx10_7_and_up(void *data,
      unsigned* width, unsigned* height)
{
   CocoaView *g_view               = cocoaview_get();
   CGRect cgrect                   = NSRectToCGRect([g_view convertRectToBacking:[g_view bounds]]);
   GLsizei backingPixelWidth       = CGRectGetWidth(cgrect);
   GLsizei backingPixelHeight      = CGRectGetHeight(cgrect);
   CGRect size                     = CGRectMake(0, 0, backingPixelWidth, backingPixelHeight);
   *width                          = CGRectGetWidth(size);
   *height                         = CGRectGetHeight(size);
}
#elif defined(OSX)
static void cocoa_gl_gfx_ctx_get_video_size(void *data,
      unsigned* width, unsigned* height)
{
   CocoaView *g_view               = cocoaview_get();
   CGRect cgrect                   = NSRectToCGRect([g_view frame]);
   GLsizei backingPixelWidth       = CGRectGetWidth(cgrect);
   GLsizei backingPixelHeight      = CGRectGetHeight(cgrect);
   CGRect size                     = CGRectMake(0, 0, backingPixelWidth, backingPixelHeight);
   *width                          = CGRectGetWidth(size);
   *height                         = CGRectGetHeight(size);
}
#else
/* iOS */
static void cocoa_gl_gfx_ctx_get_video_size(void *data,
      unsigned* width, unsigned* height)
{
   float screenscale               = cocoa_screen_get_native_scale();
   CGRect size                     = glk_view.bounds;
   *width                          = CGRectGetWidth(size)  * screenscale;
   *height                         = CGRectGetHeight(size) * screenscale;
}
#endif

static gfx_ctx_proc_t cocoa_gl_gfx_ctx_get_proc_address(const char *symbol_name)
{
   switch (cocoagl_api)
   {
      case GFX_CTX_OPENGL_API:
      case GFX_CTX_OPENGL_ES_API:
         return (gfx_ctx_proc_t)CFBundleGetFunctionPointerForName(
               CFBundleGetBundleWithIdentifier(GLFrameworkID),
               (BRIDGE CFStringRef)BOXSTRING(symbol_name)
               );
      case GFX_CTX_NONE:
      default:
         break;
   }

   return NULL;
}

static void cocoa_gl_gfx_ctx_bind_hw_render(void *data, bool enable)
{
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)data;

   switch (cocoagl_api)
   {
      case GFX_CTX_OPENGL_API:
      case GFX_CTX_OPENGL_ES_API:
         cocoa_ctx->use_hw_ctx = enable;

         if (enable)
            [g_hw_ctx makeCurrentContext];
         else
            [g_context makeCurrentContext];
         break;
      case GFX_CTX_NONE:
      default:
         break;
   }
}

static void cocoa_gl_gfx_ctx_check_window(void *data, bool *quit,
      bool *resize, unsigned *width, unsigned *height)
{
   unsigned new_width, new_height;
#ifdef HAVE_VULKAN
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)data;
#endif

   *quit                       = false;

   switch (cocoagl_api)
   {
      case GFX_CTX_OPENGL_API:
      case GFX_CTX_OPENGL_ES_API:
         break;
      case GFX_CTX_VULKAN_API:
#ifdef HAVE_VULKAN
         *resize               = cocoa_ctx->vk.need_new_swapchain;
#endif
         break;
      case GFX_CTX_NONE:
      default:
         break;
   }

#if MAC_OS_X_VERSION_10_7 && defined(OSX)
   cocoa_gl_gfx_ctx_get_video_size_osx10_7_and_up(data, &new_width, &new_height);
#else
   cocoa_gl_gfx_ctx_get_video_size(data, &new_width, &new_height);
#endif

   if (new_width != *width || new_height != *height)
   {
      *width  = new_width;
      *height = new_height;
      *resize = true;
   }
}

static void cocoa_gl_gfx_ctx_swap_interval(void *data, int i)
{
   unsigned interval           = (unsigned)i;
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)data;

   switch (cocoagl_api)
   {
      case GFX_CTX_OPENGL_API:
      case GFX_CTX_OPENGL_ES_API:
#ifdef OSX
         {
            GLint value                     = interval ? 1 : 0;
            [g_context setValues:&value forParameter:NSOpenGLCPSwapInterval];
         }
#else
         /* < No way to disable Vsync on iOS? */
         /*   Just skip presents so fast forward still works. */
         cocoa_ctx->is_syncing         = interval ? true : false;
         cocoa_ctx->fast_forward_skips = interval ? 0 : 3;
#endif
         break;
      case GFX_CTX_VULKAN_API:
#ifdef HAVE_VULKAN
         if (cocoa_ctx->swap_interval != interval)
         {
            cocoa_ctx->swap_interval = interval;
            if (cocoa_ctx->vk.swapchain)
               cocoa_ctx->vk.need_new_swapchain = true;
         }
#endif
         break;
      case GFX_CTX_NONE:
      default:
         break;
   }
}

static void cocoa_gl_gfx_ctx_swap_buffers(void *data)
{
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)data;

   switch (cocoagl_api)
   {
      case GFX_CTX_OPENGL_API:
      case GFX_CTX_OPENGL_ES_API:
#ifdef OSX
         [g_context flushBuffer];
         [g_hw_ctx  flushBuffer];
#else
         if (!(--cocoa_ctx->fast_forward_skips < 0))
            return;
         if (glk_view)
            [glk_view display];
         cocoa_ctx->fast_forward_skips = cocoa_ctx->is_syncing ? 0 : 3;
#endif
         break;
      case GFX_CTX_VULKAN_API:
#ifdef HAVE_VULKAN
         if (cocoa_ctx->vk.context.has_acquired_swapchain)
         {
            cocoa_ctx->vk.context.has_acquired_swapchain = false;
            if (cocoa_ctx->vk.swapchain == VK_NULL_HANDLE)
               retro_sleep(10);
            else
               vulkan_present(&cocoa_ctx->vk, cocoa_ctx->vk.context.current_swapchain_index);
         }
         vulkan_acquire_next_image(&cocoa_ctx->vk);
#endif
         break;
      case GFX_CTX_NONE:
      default:
         break;
   }
}

static bool cocoa_gl_gfx_ctx_bind_api(void *data, enum gfx_ctx_api api,
      unsigned major, unsigned minor)
{
   switch (api)
   {
#if defined(HAVE_COCOATOUCH)
      case GFX_CTX_OPENGL_ES_API:
         break;
#elif defined(HAVE_COCOA) || defined(HAVE_COCOA_METAL)
      case GFX_CTX_OPENGL_API:
         break;
#ifdef HAVE_VULKAN
      case GFX_CTX_VULKAN_API:
         break;
#endif
#endif
      case GFX_CTX_NONE:
      default:
         return false;
   }

   cocoagl_api = api;
   g_minor     = minor;
   g_major     = major;

   return true;
}

#ifdef HAVE_VULKAN
static void *cocoa_vk_gfx_ctx_get_context_data(void *data)
{
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)data;
   return &cocoa_ctx->vk.context;
}
#endif

#ifdef OSX
static bool cocoa_gl_gfx_ctx_set_video_mode(void *data,
      unsigned width, unsigned height, bool fullscreen)
{
#if defined(HAVE_COCOA_METAL)
   NSView *g_view              = apple_platform.renderView;
#elif defined(HAVE_COCOA)
   CocoaView *g_view           = (CocoaView*)nsview_get_ptr();
#endif
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)data;
   static bool 
      has_went_fullscreen      = false;
   cocoa_ctx->width            = width;
   cocoa_ctx->height           = height;

   switch (cocoagl_api)
   {
      case GFX_CTX_OPENGL_API:
      case GFX_CTX_OPENGL_ES_API:
         /* NOTE: setWantsBestResolutionOpenGLSurface only available on MacOS X 10.7 and up.
          * Deprecated as of MacOS X 10.14. */
#if MAC_OS_X_VERSION_10_7
         [g_view setWantsBestResolutionOpenGLSurface:YES];
#endif

         {
            NSOpenGLPixelFormatAttribute attributes [] = {
               NSOpenGLPFAColorSize,
               24,
               NSOpenGLPFADoubleBuffer,
               NSOpenGLPFAAllowOfflineRenderers,
               NSOpenGLPFADepthSize,
               (NSOpenGLPixelFormatAttribute)16, /* 16 bit depth buffer */
               0,                                /* profile */
               0,                                /* profile enum */
               (NSOpenGLPixelFormatAttribute)0
            };

            switch (g_major)
            {
               case 3:
#if MAC_OS_X_VERSION_10_7
                  if (g_minor >= 1 && g_minor <= 3)
                  {
                     attributes[6] = NSOpenGLPFAOpenGLProfile;
                     attributes[7] = NSOpenGLProfileVersion3_2Core;
                  }
#endif
                  break;
               case 4:
#if MAC_OS_X_VERSION_10_10
                  if (g_minor == 1)
                  {
                     attributes[6] = NSOpenGLPFAOpenGLProfile;
                     attributes[7] = NSOpenGLProfileVersion4_1Core;
                  }
#endif
                  break;
            }

            g_format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];

#if MAC_OS_X_VERSION_MIN_REQUIRED < 1050
            if (g_format == nil)
            {
               /* NSOpenGLFPAAllowOfflineRenderers is
                  not supported on this OS version. */
               attributes[3] = (NSOpenGLPixelFormatAttribute)0;
               g_format      = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
            }
#endif
         }

         if (cocoa_ctx->use_hw_ctx)
         {
            g_hw_ctx       = [[NSOpenGLContext alloc] initWithFormat:g_format shareContext:nil];
            g_context      = [[NSOpenGLContext alloc] initWithFormat:g_format shareContext:g_hw_ctx];
         }
         else
            g_context      = [[NSOpenGLContext alloc] initWithFormat:g_format shareContext:nil];

         [g_context setView:g_view];
         [g_context makeCurrentContext];
         break;
      case GFX_CTX_VULKAN_API:
#ifdef HAVE_VULKAN
         RARCH_LOG("[macOS]: Native window size: %u x %u.\n",
               cocoa_ctx->width, cocoa_ctx->height);

         if (!vulkan_surface_create(
                  &cocoa_ctx->vk,
                  VULKAN_WSI_MVK_MACOS,
                  NULL,
                  (BRIDGE void *)g_view,
                  cocoa_ctx->width,
                  cocoa_ctx->height,
                  cocoa_ctx->swap_interval))
         {
            RARCH_ERR("[macOS]: Failed to create surface.\n");
            return false;
         }
#endif
         break;
      case GFX_CTX_NONE:
      default:
         break;
   }

   /* TODO: Screen mode support. */
   if (fullscreen)
   {
      if (!has_went_fullscreen)
      {
         [g_view enterFullScreenMode:(BRIDGE NSScreen *)cocoa_screen_get_chosen() withOptions:nil];
         cocoa_show_mouse(data, false);
      }
   }
   else
   {
      if (has_went_fullscreen)
      {
         [g_view exitFullScreenModeWithOptions:nil];
         [[g_view window] makeFirstResponder:g_view];
         cocoa_show_mouse(data, true);
      }

      [[g_view window] setContentSize:NSMakeSize(width, height)];
   }

   has_went_fullscreen = fullscreen;

   return true;
}

static void *cocoa_gl_gfx_ctx_init(void *video_driver)
{
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)
   calloc(1, sizeof(cocoa_ctx_data_t));

   if (!cocoa_ctx)
      return NULL;

#ifndef OSX
   cocoa_ctx->is_syncing       = true;
#endif
    
   switch (cocoagl_api)
   {
#if defined(HAVE_COCOA_METAL)
      case GFX_CTX_OPENGL_API:
         [apple_platform setViewType:APPLE_VIEW_TYPE_OPENGL];
         break;
#endif
      case GFX_CTX_VULKAN_API:
#ifdef HAVE_VULKAN
         [apple_platform setViewType:APPLE_VIEW_TYPE_VULKAN];
         if (!vulkan_context_init(&cocoa_ctx->vk, VULKAN_WSI_MVK_MACOS))
         {
            free(cocoa_ctx);
            return NULL;
         }
#endif
         break;
      case GFX_CTX_NONE:
      default:
         break;
   }
    
   return cocoa_ctx;
}
#else
static bool cocoa_gl_gfx_ctx_set_video_mode(void *data,
      unsigned width, unsigned height, bool fullscreen)
{
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)data;

   switch (cocoagl_api)
   {
      case GFX_CTX_OPENGL_API:
      case GFX_CTX_OPENGL_ES_API:
         if (cocoa_ctx->use_hw_ctx)
            g_hw_ctx      = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
         g_context        = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
         glk_view.context = g_context;

         [g_context makeCurrentContext];
         break;
      case GFX_CTX_NONE:
      default:
         break;
   }

   /* TODO: Maybe iOS users should be able to 
    * show/hide the status bar here? */
   return true;
}

static void *cocoa_gl_gfx_ctx_init(void *video_driver)
{
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)
   calloc(1, sizeof(cocoa_ctx_data_t));

   if (!cocoa_ctx)
      return NULL;

#ifndef OSX
   cocoa_ctx->is_syncing       = true;
#endif
    
   switch (cocoagl_api)
   {
      case GFX_CTX_OPENGL_ES_API:
#if defined(HAVE_COCOA_METAL)
         /* The Metal build supports both the OpenGL 
          * and Metal video drivers */
         [apple_platform setViewType:APPLE_VIEW_TYPE_OPENGL_ES];
#endif
         break;
      case GFX_CTX_NONE:
      default:
         break;
   }
    
   return cocoa_ctx;
}
#endif

#ifdef HAVE_COCOA_METAL
static bool cocoa_gl_gfx_ctx_set_resize(void *data, unsigned width, unsigned height)
{
#ifdef HAVE_VULKAN
   cocoa_ctx_data_t *cocoa_ctx = (cocoa_ctx_data_t*)data;
#endif

   switch (cocoagl_api)
   {
      case GFX_CTX_OPENGL_API:
      case GFX_CTX_OPENGL_ES_API:
         break;
      case GFX_CTX_VULKAN_API:
#ifdef HAVE_VULKAN
         cocoa_ctx->width  = width;
         cocoa_ctx->height = height;

         if (!vulkan_create_swapchain(&cocoa_ctx->vk,
                  width, height, cocoa_ctx->swap_interval))
         {
            RARCH_ERR("[macOS/Vulkan]: Failed to update swapchain.\n");
            return false;
         }

         cocoa_ctx->vk.context.invalid_swapchain = true;
         if (cocoa_ctx->vk.created_new_swapchain)
            vulkan_acquire_next_image(&cocoa_ctx->vk);

         cocoa_ctx->vk.need_new_swapchain        = false;
#endif
         break;
      case GFX_CTX_NONE:
      default:
         break;
   }

   return true;
}
#endif

const gfx_ctx_driver_t gfx_ctx_cocoagl = {
   cocoa_gl_gfx_ctx_init,
   cocoa_gl_gfx_ctx_destroy,
   cocoa_gl_gfx_ctx_get_api,
   cocoa_gl_gfx_ctx_bind_api,
   cocoa_gl_gfx_ctx_swap_interval,
   cocoa_gl_gfx_ctx_set_video_mode,
#if MAC_OS_X_VERSION_10_7 && defined(OSX)
   cocoa_gl_gfx_ctx_get_video_size_osx10_7_and_up,
#else
   cocoa_gl_gfx_ctx_get_video_size,
#endif
   NULL, /* get_refresh_rate */
   NULL, /* get_video_output_size */
   NULL, /* get_video_output_prev */
   NULL, /* get_video_output_next */
   cocoa_gl_gfx_ctx_get_metrics,
   NULL, /* translate_aspect */
#ifdef OSX
   cocoa_update_title,
#else
   NULL, /* update_title */
#endif
   cocoa_gl_gfx_ctx_check_window,
#if defined(HAVE_COCOA_METAL)
   cocoagl_gfx_ctx_set_resize,
#else
   NULL, /* set_resize */
#endif
   cocoa_has_focus,
   cocoa_gl_gfx_ctx_suppress_screensaver,
#if defined(HAVE_COCOATOUCH)
   false,
#else
   true,
#endif
   cocoa_gl_gfx_ctx_swap_buffers,
   cocoa_gl_gfx_ctx_input_driver,
   cocoa_gl_gfx_ctx_get_proc_address,
   NULL, /* image_buffer_init */
   NULL, /* image_buffer_write */
   NULL, /* show_mouse */
   "cocoagl",
   cocoa_gl_gfx_ctx_get_flags,
   cocoa_gl_gfx_ctx_set_flags,
   cocoa_gl_gfx_ctx_bind_hw_render,
#if defined(HAVE_VULKAN)
   cocoa_vk_gfx_ctx_get_context_data,
#else
   NULL, /* get_context_data */
#endif
   NULL  /* make_current */
};
