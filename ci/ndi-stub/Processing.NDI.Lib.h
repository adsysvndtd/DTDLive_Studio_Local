// CI-only stand-in for the NDI® SDK for Apple (the real SDK is licensed by Vizrt and is not in this repo).
// It declares only the parts DTDStudio uses, with the same names, types and layouts as NDI SDK 5/6, so CI can
// compile the NDI code paths (NDI_SDK). It is never shipped: local builds use the real SDK from scripts/ndi-setup.sh.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#define NDIlib_send_timecode_synthesize INT64_MAX

typedef void* NDIlib_find_instance_t;
typedef void* NDIlib_recv_instance_t;
typedef void* NDIlib_send_instance_t;

typedef enum NDIlib_frame_type_e {
    NDIlib_frame_type_none = 0, NDIlib_frame_type_video = 1, NDIlib_frame_type_audio = 2,
    NDIlib_frame_type_metadata = 3, NDIlib_frame_type_error = 4, NDIlib_frame_type_status_change = 100,
    NDIlib_frame_type_max = 0x7fffffff
} NDIlib_frame_type_e;

typedef enum NDIlib_FourCC_video_type_e {
    NDIlib_FourCC_video_type_UYVY = 0x59565955, NDIlib_FourCC_video_type_NV12 = 0x3231564E,
    NDIlib_FourCC_video_type_BGRA = 0x41524742, NDIlib_FourCC_video_type_BGRX = 0x58524742,
    NDIlib_FourCC_video_type_max = 0x7fffffff
} NDIlib_FourCC_video_type_e;

typedef enum NDIlib_frame_format_type_e {
    NDIlib_frame_format_type_progressive = 1, NDIlib_frame_format_type_interleaved = 0,
    NDIlib_frame_format_type_field_0 = 2, NDIlib_frame_format_type_field_1 = 3,
    NDIlib_frame_format_type_max = 0x7fffffff
} NDIlib_frame_format_type_e;

typedef enum NDIlib_recv_bandwidth_e {
    NDIlib_recv_bandwidth_metadata_only = -10, NDIlib_recv_bandwidth_audio_only = 10,
    NDIlib_recv_bandwidth_lowest = 0, NDIlib_recv_bandwidth_highest = 100, NDIlib_recv_bandwidth_max = 0x7fffffff
} NDIlib_recv_bandwidth_e;

typedef enum NDIlib_recv_color_format_e {
    NDIlib_recv_color_format_BGRX_BGRA = 0, NDIlib_recv_color_format_UYVY_BGRA = 1,
    NDIlib_recv_color_format_RGBX_RGBA = 2, NDIlib_recv_color_format_UYVY_RGBA = 3,
    NDIlib_recv_color_format_fastest = 100, NDIlib_recv_color_format_best = 101,
    NDIlib_recv_color_format_max = 0x7fffffff
} NDIlib_recv_color_format_e;

typedef struct NDIlib_source_t {
    const char* p_ndi_name;
    union { const char* p_url_address; const char* p_ip_address; };
} NDIlib_source_t;

typedef struct NDIlib_find_create_t {
    bool show_local_sources;
    const char* p_groups;
    const char* p_extra_ips;
} NDIlib_find_create_t;

typedef struct NDIlib_video_frame_v2_t {
    int xres, yres;
    NDIlib_FourCC_video_type_e FourCC;
    int frame_rate_N, frame_rate_D;
    float picture_aspect_ratio;
    NDIlib_frame_format_type_e frame_format_type;
    int64_t timecode;
    uint8_t* p_data;
    union { int line_stride_in_bytes; int data_size_in_bytes; };
    const char* p_metadata;
    int64_t timestamp;
} NDIlib_video_frame_v2_t;

typedef struct NDIlib_audio_frame_v2_t {
    int sample_rate;
    int no_channels;
    int no_samples;
    int64_t timecode;
    float* p_data;
    int channel_stride_in_bytes;
    const char* p_metadata;
    int64_t timestamp;
} NDIlib_audio_frame_v2_t;

typedef struct NDIlib_metadata_frame_t {
    int length;
    int64_t timecode;
    char* p_data;
} NDIlib_metadata_frame_t;

typedef struct NDIlib_tally_t {
    bool on_program;
    bool on_preview;
} NDIlib_tally_t;

typedef struct NDIlib_recv_create_v3_t {
    NDIlib_source_t source_to_connect_to;
    NDIlib_recv_color_format_e color_format;
    NDIlib_recv_bandwidth_e bandwidth;
    bool allow_video_fields;
    const char* p_ndi_recv_name;
} NDIlib_recv_create_v3_t;

typedef struct NDIlib_send_create_t {
    const char* p_ndi_name;
    const char* p_groups;
    bool clock_video;
    bool clock_audio;
} NDIlib_send_create_t;

bool NDIlib_initialize(void);

NDIlib_find_instance_t NDIlib_find_create_v2(const NDIlib_find_create_t* p_create_settings);
void NDIlib_find_destroy(NDIlib_find_instance_t p_instance);
bool NDIlib_find_wait_for_sources(NDIlib_find_instance_t p_instance, uint32_t timeout_in_ms);
const NDIlib_source_t* NDIlib_find_get_current_sources(NDIlib_find_instance_t p_instance, uint32_t* p_no_sources);

NDIlib_recv_instance_t NDIlib_recv_create_v3(const NDIlib_recv_create_v3_t* p_create_settings);
void NDIlib_recv_destroy(NDIlib_recv_instance_t p_instance);
NDIlib_frame_type_e NDIlib_recv_capture_v2(NDIlib_recv_instance_t p_instance, NDIlib_video_frame_v2_t* p_video_data,
                                           NDIlib_audio_frame_v2_t* p_audio_data, NDIlib_metadata_frame_t* p_metadata,
                                           uint32_t timeout_in_ms);
void NDIlib_recv_free_video_v2(NDIlib_recv_instance_t p_instance, const NDIlib_video_frame_v2_t* p_video_data);
void NDIlib_recv_free_audio_v2(NDIlib_recv_instance_t p_instance, const NDIlib_audio_frame_v2_t* p_audio_data);
bool NDIlib_recv_set_tally(NDIlib_recv_instance_t p_instance, const NDIlib_tally_t* p_tally);
int NDIlib_recv_get_no_connections(NDIlib_recv_instance_t p_instance);

bool NDIlib_recv_ptz_is_supported(NDIlib_recv_instance_t p_instance);
bool NDIlib_recv_ptz_pan_tilt_speed(NDIlib_recv_instance_t p_instance, const float pan_speed, const float tilt_speed);
bool NDIlib_recv_ptz_zoom_speed(NDIlib_recv_instance_t p_instance, const float zoom_speed);
bool NDIlib_recv_ptz_focus_speed(NDIlib_recv_instance_t p_instance, const float focus_speed);
bool NDIlib_recv_ptz_auto_focus(NDIlib_recv_instance_t p_instance);
bool NDIlib_recv_ptz_store_preset(NDIlib_recv_instance_t p_instance, const int preset_no);
bool NDIlib_recv_ptz_recall_preset(NDIlib_recv_instance_t p_instance, const int preset_no, const float speed);

NDIlib_send_instance_t NDIlib_send_create(const NDIlib_send_create_t* p_create_settings);
void NDIlib_send_destroy(NDIlib_send_instance_t p_instance);
void NDIlib_send_send_video_v2(NDIlib_send_instance_t p_instance, const NDIlib_video_frame_v2_t* p_video_data);
void NDIlib_send_send_audio_v2(NDIlib_send_instance_t p_instance, const NDIlib_audio_frame_v2_t* p_audio_data);
