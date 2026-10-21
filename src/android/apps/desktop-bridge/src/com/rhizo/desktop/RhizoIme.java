package com.rhizo.desktop;

import android.inputmethodservice.InputMethodService;
import android.view.View;

// default input method for clipboard access
public class RhizoIme extends InputMethodService {
    // call BridgeService.startIfMinted
    @Override
    public void onCreate() {
        super.onCreate();
        BridgeService.startIfMinted(this, "ime");
    }

    // return no input view
    @Override
    public View onCreateInputView() {
        return null;
    }

    // report that no input view is shown
    @Override
    public boolean onEvaluateInputViewShown() {
        return false;
    }
}
