package org.rhizo.headroomprobe;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.os.CpuHeadroomParams;
import android.os.SystemClock;
import android.os.health.SystemHealthManager;
import android.util.Log;
import android.util.Pair;
import android.widget.TextView;

import java.io.File;
import java.io.FileWriter;
import java.io.IOException;

// activity for CPU headroom sampling
public class Probe extends Activity {
    private static final String TAG = "RhizoHeadroom";
    private static final String DEFAULT_OUT = "headroom.txt";

    private FileWriter out;
    private int samples;
    private int nan;

    // read the intent extras and start the sampling thread
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        TextView tv = new TextView(this);
        tv.setText("rhizo headroom probe");
        setContentView(tv);
        Intent in = getIntent();
        final int durationS = in.getIntExtra("duration_s", 0);
        final String type = in.hasExtra("type") ? in.getStringExtra("type") : "min";
        final int windowMs = in.getIntExtra("window_ms", 1000);
        final String outName = in.hasExtra("out") ? in.getStringExtra("out") : DEFAULT_OUT;
        openOut(outName);
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                sampleLoop(durationS, type, windowMs);
            }
        }, "headroom-sampler");
        t.start();
    }

    // open the output file
    private void openOut(String name) {
        File[] dirs = getExternalMediaDirs();
        File dir = dirs.length > 0 ? dirs[0] : null;
        if (dir == null || (!dir.isDirectory() && !dir.mkdirs())) {
            Log.e(TAG, "RHIZO_HEADROOM_OUT_ERROR no external media dir");
            return;
        }
        try {
            out = new FileWriter(new File(dir, name), false);
        } catch (IOException e) {
            Log.e(TAG, "RHIZO_HEADROOM_OUT_ERROR " + e);
        }
    }

    // log the line and append it to the output file
    private synchronized void emit(String line) {
        Log.i(TAG, line);
        if (out == null) {
            return;
        }
        try {
            out.write(line + "\n");
            out.flush();
        } catch (IOException e) {
            Log.e(TAG, "RHIZO_HEADROOM_OUT_ERROR " + e);
        }
    }

    // return the name of a headroom calculation type
    private static String typeName(int calc) {
        return calc == CpuHeadroomParams.CPU_HEADROOM_CALCULATION_TYPE_MIN ? "min" : "average";
    }

    // emit a Java sample line
    private void sampleJava(SystemHealthManager shm, int calc, int windowMs) {
        String value;
        try {
            CpuHeadroomParams p = new CpuHeadroomParams.Builder()
                    .setCalculationType(calc).setCalculationWindowMillis(windowMs).build();
            float v = shm.getCpuHeadroom(p);
            if (Float.isNaN(v)) {
                value = "NaN";
                nan++;
            } else {
                value = String.valueOf(v);
            }
        } catch (UnsupportedOperationException e) {
            value = "unsupported";
        } catch (RuntimeException e) {
            value = "error:" + e.getClass().getSimpleName();
        }
        long t = SystemClock.elapsedRealtimeNanos();
        samples++;
        emit("RHIZO_HEADROOM api=java t_ns=" + t + " type=" + typeName(calc) + " window=" + windowMs + " value=" + value);
    }

    // emit a native sample line
    private void sampleNdk(int calc, int windowMs) {
        String r;
        try {
            System.loadLibrary("headroomprobe");
            r = ndkSample(calc, windowMs);
        } catch (UnsatisfiedLinkError e) {
            r = "rc=-1 value=error:UnsatisfiedLinkError";
        }
        long t = SystemClock.elapsedRealtimeNanos();
        emit("RHIZO_HEADROOM api=ndk t_ns=" + t + " type=" + typeName(calc) + " window=" + windowMs + " " + r);
    }

    // sample the CPU headroom for the duration
    private void sampleLoop(int durationS, String type, int windowMs) {
        SystemHealthManager shm = getSystemService(SystemHealthManager.class);
        long intervalMs = 0;
        boolean supported = true;
        try {
            intervalMs = shm.getCpuHeadroomMinIntervalMillis();
            Pair<Integer, Integer> range = shm.getCpuHeadroomCalculationWindowRange();
            emit("RHIZO_HEADROOM_INFO supported=1 min_interval_ms=" + intervalMs
                    + " window_min=" + range.first + " window_max=" + range.second);
        } catch (UnsupportedOperationException e) {
            supported = false;
            emit("RHIZO_HEADROOM_INFO supported=0");
        }
        int first = type.equals("average") ? CpuHeadroomParams.CPU_HEADROOM_CALCULATION_TYPE_AVERAGE
                : CpuHeadroomParams.CPU_HEADROOM_CALCULATION_TYPE_MIN;
        sampleNdk(first, windowMs);
        long deadline = SystemClock.elapsedRealtime() + durationS * 1000L;
        int n = 0;
        do {
            int calc = first;
            if (type.equals("both")) {
                calc = (n % 2 == 0) ? CpuHeadroomParams.CPU_HEADROOM_CALCULATION_TYPE_MIN
                        : CpuHeadroomParams.CPU_HEADROOM_CALCULATION_TYPE_AVERAGE;
            }
            sampleJava(shm, calc, windowMs);
            n++;
            if (!supported || durationS == 0) {
                break;
            }
            try {
                Thread.sleep(intervalMs);
            } catch (InterruptedException e) {
                break;
            }
        } while (SystemClock.elapsedRealtime() < deadline);
        emit("RHIZO_HEADROOM_DONE samples=" + samples + " nan=" + nan);
    }

    private static native String ndkSample(int calc, int windowMs);
}
