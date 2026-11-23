// Stub bodies for the CI NDI compile check (never shipped).
#include "Processing.NDI.Lib.h"
#include <stddef.h>
bool NDIlib_initialize(void) { return false; }
NDIlib_find_instance_t NDIlib_find_create_v2(const NDIlib_find_create_t* p_create_settings) { return NULL; }
void NDIlib_find_destroy(NDIlib_find_instance_t p_instance) {}
bool NDIlib_find_wait_for_sources(NDIlib_find_instance_t p_instance, uint32_t timeout_in_ms) { return false; }
const NDIlib_source_t* NDIlib_find_get_current_sources(NDIlib_find_instance_t p_instance, uint32_t* p_no_sources) { return NULL; }
NDIlib_recv_instance_t NDIlib_recv_create_v3(const NDIlib_recv_create_v3_t* p_create_settings) { return NULL; }
void NDIlib_recv_destroy(NDIlib_recv_instance_t p_instance) {}
NDIlib_frame_type_e NDIlib_recv_capture_v2(NDIlib_recv_instance_t p_instance, NDIlib_video_frame_v2_t* p_video_data, NDIlib_audio_frame_v2_t* p_audio_data, NDIlib_metadata_frame_t* p_metadata, uint32_t timeout_in_ms) { return NDIlib_frame_type_none; }
void NDIlib_recv_free_video_v2(NDIlib_recv_instance_t p_instance, const NDIlib_video_frame_v2_t* p_video_data) {}
void NDIlib_recv_free_audio_v2(NDIlib_recv_instance_t p_instance, const NDIlib_audio_frame_v2_t* p_audio_data) {}
bool NDIlib_recv_set_tally(NDIlib_recv_instance_t p_instance, const NDIlib_tally_t* p_tally) { return false; }
int NDIlib_recv_get_no_connections(NDIlib_recv_instance_t p_instance) { return 0; }
bool NDIlib_recv_ptz_is_supported(NDIlib_recv_instance_t p_instance) { return false; }
bool NDIlib_recv_ptz_pan_tilt_speed(NDIlib_recv_instance_t p_instance, const float pan_speed, const float tilt_speed) { return false; }
bool NDIlib_recv_ptz_zoom_speed(NDIlib_recv_instance_t p_instance, const float zoom_speed) { return false; }
bool NDIlib_recv_ptz_focus_speed(NDIlib_recv_instance_t p_instance, const float focus_speed) { return false; }
bool NDIlib_recv_ptz_auto_focus(NDIlib_recv_instance_t p_instance) { return false; }
bool NDIlib_recv_ptz_store_preset(NDIlib_recv_instance_t p_instance, const int preset_no) { return false; }
bool NDIlib_recv_ptz_recall_preset(NDIlib_recv_instance_t p_instance, const int preset_no, const float speed) { return false; }
NDIlib_send_instance_t NDIlib_send_create(const NDIlib_send_create_t* p_create_settings) { return NULL; }
void NDIlib_send_destroy(NDIlib_send_instance_t p_instance) {}
void NDIlib_send_send_video_v2(NDIlib_send_instance_t p_instance, const NDIlib_video_frame_v2_t* p_video_data) {}
void NDIlib_send_send_audio_v2(NDIlib_send_instance_t p_instance, const NDIlib_audio_frame_v2_t* p_audio_data) {}
