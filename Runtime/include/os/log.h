/* os/log.h - a subset of Apple's os_log API on top of Performance Dashboard.

   Messages go into the trace (the "os_log" table) while recording and are
   otherwise discarded.  */

#ifndef GSP_OS_LOG_H
#define GSP_OS_LOG_H

#include <GSPerformance/gsp_signpost.h>

typedef gsp_log_t os_log_t;

#define OS_LOG_DEFAULT GSP_LOG_DEFAULT
#define OS_LOG_DISABLED ((os_log_t)0)

#define OS_LOG_TYPE_DEFAULT GSP_LOG_LEVEL_DEFAULT
#define OS_LOG_TYPE_INFO GSP_LOG_LEVEL_INFO
#define OS_LOG_TYPE_DEBUG GSP_LOG_LEVEL_DEBUG
#define OS_LOG_TYPE_ERROR GSP_LOG_LEVEL_ERROR
#define OS_LOG_TYPE_FAULT GSP_LOG_LEVEL_FAULT

#define os_log_create(subsystem, category) gsp_log_create((subsystem), (category))

#define os_log_with_type(log, type, ...) gsp_log_emit((log), (type), __VA_ARGS__)
#define os_log(log, ...) gsp_log_emit((log), GSP_LOG_LEVEL_DEFAULT, __VA_ARGS__)
#define os_log_info(log, ...) gsp_log_emit((log), GSP_LOG_LEVEL_INFO, __VA_ARGS__)
#define os_log_debug(log, ...) gsp_log_emit((log), GSP_LOG_LEVEL_DEBUG, __VA_ARGS__)
#define os_log_error(log, ...) gsp_log_emit((log), GSP_LOG_LEVEL_ERROR, __VA_ARGS__)
#define os_log_fault(log, ...) gsp_log_emit((log), GSP_LOG_LEVEL_FAULT, __VA_ARGS__)

#endif
