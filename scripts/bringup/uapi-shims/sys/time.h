#ifndef RMX1901_UAPI_ORACLE_SYS_TIME_H
#define RMX1901_UAPI_ORACLE_SYS_TIME_H

/* Android vendor headers only need the target-ABI layout of timeval here. */
typedef long time_t;
typedef long suseconds_t;

struct timeval {
	time_t tv_sec;
	suseconds_t tv_usec;
};

struct timespec {
	time_t tv_sec;
	long tv_nsec;
};

#endif
