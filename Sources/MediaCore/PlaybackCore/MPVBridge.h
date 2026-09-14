#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

typedef struct MivuMPV MivuMPV;

MivuMPV *mivu_mpv_create(void);
void mivu_mpv_destroy(MivuMPV *player);
int mivu_mpv_is_initialized(MivuMPV *player);
int mivu_mpv_load(MivuMPV *player, const char *url, const char *headers, double start_position, int start_paused);
int mivu_mpv_stop(MivuMPV *player);
int mivu_mpv_set_paused(MivuMPV *player, int paused);
int mivu_mpv_seek(MivuMPV *player, double position);
int mivu_mpv_set_rate(MivuMPV *player, double rate);
int mivu_mpv_set_volume(MivuMPV *player, double volume);
int mivu_mpv_set_muted(MivuMPV *player, int muted);
int mivu_mpv_poll_event(MivuMPV *player, int *end_reason, int *end_error);
int mivu_mpv_snapshot(MivuMPV *player, double *time, double *duration, double *buffered, int *paused);
const char *mivu_mpv_last_error(MivuMPV *player);
const char *mivu_mpv_current_hwdec(MivuMPV *player);
int mivu_mpv_set_subtitle_id(MivuMPV *player, int subtitle_id);
int mivu_mpv_add_subtitle(MivuMPV *player, const char *url);
int mivu_mpv_set_subtitle_scale(MivuMPV *player, double scale);
int mivu_mpv_set_subtitle_delay(MivuMPV *player, double delay);
int mivu_mpv_set_subtitle_position(MivuMPV *player, int position);
int mivu_mpv_set_secondary_subtitle_id(MivuMPV *player, int subtitle_id);
int mivu_mpv_set_voice_boost(MivuMPV *player, int enabled);
int mivu_mpv_frame_step(MivuMPV *player, int forward);
int mivu_mpv_screenshot(MivuMPV *player, const char *filepath, int include_subtitles);
int mivu_mpv_set_resource_limits(MivuMPV *player, int maximum_bitrate_bps, int64_t cache_limit_bytes);

// Plan B: CoreVideo + AVSampleBufferDisplayLayer APIs
int mivu_mpv_init_renderer(MivuMPV *player);
CMSampleBufferRef mivu_mpv_render_sample_buffer(MivuMPV *player, int target_width, int target_height) CF_RETURNS_RETAINED;
void mivu_mpv_flush_renderer(MivuMPV *player);
int mivu_mpv_get_video_size(MivuMPV *player, int *width, int *height);
int mivu_mpv_has_new_frame(MivuMPV *player);
