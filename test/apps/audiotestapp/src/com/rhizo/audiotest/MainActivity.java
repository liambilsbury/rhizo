package com.rhizo.audiotest;

import android.app.Activity;
import android.graphics.Color;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.os.Bundle;
import android.util.Log;
import android.view.Gravity;
import android.widget.TextView;

// activity for sine tone playback
public class MainActivity extends Activity {
    private static final String TAG = "RhizoAudioTest";
    private static final int RATE = 48000;

    private AudioTrack mTrack;
    private Thread mThread;
    private volatile boolean mRunning;

    // show the tone details and start the tone thread
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        TextView tv = new TextView(this);
        tv.setText(Config.TONE_HZ + " Hz\n" + getPackageName());
        tv.setTextSize(48);
        tv.setGravity(Gravity.CENTER);
        tv.setTextColor(Color.WHITE);
        tv.setBackgroundColor(Config.BACKGROUND);
        setContentView(tv);
        start();
    }

    // start the tone playback thread
    private void start() {
        mRunning = true;
        mThread = new Thread(new Runnable() {
            @Override
            public void run() {
                int minBytes = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_STEREO,
                        AudioFormat.ENCODING_PCM_16BIT);
                if (minBytes <= 0) {
                    Log.e(TAG, "getMinBufferSize returned " + minBytes + " -- no usable output");
                    return;
                }
                int bufBytes = Math.max(minBytes, RATE / 5 * 4);
                mTrack = new AudioTrack.Builder()
                        .setAudioAttributes(new AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_MEDIA)
                                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                                .build())
                        .setAudioFormat(new AudioFormat.Builder()
                                .setSampleRate(RATE)
                                .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                                .build())
                        .setBufferSizeInBytes(bufBytes)
                        .setTransferMode(AudioTrack.MODE_STREAM)
                        .build();
                mTrack.play();
                Log.i(TAG, "RHIZO_AUDIO_PLAYING pkg=" + getPackageName()
                        + " hz=" + Config.TONE_HZ + " buffer=" + bufBytes);

                short[] chunk = new short[RATE * 2];
                for (int i = 0; i < RATE; i++) {
                    short v = (short) (12000.0
                            * Math.sin(2.0 * Math.PI * Config.TONE_HZ * i / RATE));
                    chunk[i * 2] = v;
                    chunk[i * 2 + 1] = v;
                }
                long written = 0;
                while (mRunning) {
                    int n = mTrack.write(chunk, 0, chunk.length);
                    if (n < 0) {
                        Log.e(TAG, "AudioTrack.write failed: " + n);
                        break;
                    }
                    written += n;
                    Log.i(TAG, "RHIZO_AUDIO_WROTE " + written + " samples");
                }
            }
        }, "tone");
        mThread.start();
    }

    // stop and release the audio track
    @Override
    protected void onDestroy() {
        mRunning = false;
        if (mTrack != null) {
            mTrack.stop();
            mTrack.release();
            mTrack = null;
        }
        super.onDestroy();
    }
}
