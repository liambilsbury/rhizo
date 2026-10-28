package android.location.provider;

import android.content.Context;
import android.location.Location;
import android.os.Bundle;
import android.os.IBinder;

// compile-time stub for the LocationProviderBase system API
public abstract class LocationProviderBase {
    public interface OnFlushCompleteCallback {
        void onFlushComplete();
    }

    public LocationProviderBase(Context context, String tag, ProviderProperties properties) {}

    public final IBinder getBinder() { return null; }

    public void reportLocation(Location location) {}

    public abstract void onSetRequest(ProviderRequest request);

    public abstract void onFlush(OnFlushCompleteCallback callback);

    public abstract void onSendExtraCommand(String command, Bundle extras);
}
