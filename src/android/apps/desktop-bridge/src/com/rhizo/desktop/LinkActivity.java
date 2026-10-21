package com.rhizo.desktop;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;

import org.json.JSONException;
import org.json.JSONObject;

// activity for forwarding links
public class LinkActivity extends Activity {
    // forward the shared or opened link to the host and finish
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Intent intent = getIntent();
        String uri = Intent.ACTION_SEND.equals(intent.getAction())
                ? intent.getStringExtra(Intent.EXTRA_TEXT)
                : uriString(intent.getData());
        if (uri != null) {
            forward(uri, intent.getType());
        }
        finish();
    }

    // send the open message to BridgeService
    private void forward(String uri, String mime) {
        JSONObject obj = new JSONObject();
        try {
            obj.put("t", "open");
            obj.put("uri", uri);
            obj.put("mime", mime != null ? mime : JSONObject.NULL);
        } catch (JSONException e) {
            Logs.e("cannot build open payload", e);
            return;
        }
        BridgeService.enqueue(this, obj);
        Logs.i("RHIZO_LINK_FORWARDED uri=" + uri);
    }

    // return the uri as a string or null
    private static String uriString(Uri uri) {
        return uri == null ? null : uri.toString();
    }
}
