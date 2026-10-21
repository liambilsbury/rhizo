#include <android/system_health.h>
#include <errno.h>
#include <jni.h>
#include <math.h>
#include <stdio.h>

// get an NDK CPU headroom sample
JNIEXPORT jstring JNICALL
Java_org_rhizo_headroomprobe_Probe_ndkSample(JNIEnv *env, jclass cls, jint type, jint window_ms)
{
	char buf[96];
	(void)cls;

	if (__builtin_available(android 36, *)) {
		ACpuHeadroomParams *params = ACpuHeadroomParams_create();
		float value = 0.0f;
		int rc;

		ACpuHeadroomParams_setCalculationType(params, (ACpuHeadroomCalculationType)type);
		ACpuHeadroomParams_setCalculationWindowMillis(params, window_ms);
		rc = ASystemHealth_getCpuHeadroom(params, &value);
		ACpuHeadroomParams_destroy(params);
		if (rc == 0) {
			if (isnan(value))
				snprintf(buf, sizeof buf, "rc=0 value=NaN");
			else
				snprintf(buf, sizeof buf, "rc=0 value=%.2f", value);
		} else if (rc == ENOTSUP) {
			snprintf(buf, sizeof buf, "rc=%d value=unsupported", rc);
		} else {
			snprintf(buf, sizeof buf, "rc=%d value=error:errno%d", rc, rc);
		}
	} else {
		snprintf(buf, sizeof buf, "rc=-1 value=error:no-ndk-symbol");
	}
	return (*env)->NewStringUTF(env, buf);
}
