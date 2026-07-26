// Reynard Safe Area Detector — background script
//
// The actual native-messaging relay point, specifically because that
// path is confirmed working from a background script even where it's
// broken from a content script directly (see content.js's own comment).
// "reynard" here must match whatever nativeApp identifier the native
// Swift side registers as its own listener.
browser.runtime.onMessage.addListener((message, sender) => {
  browser.runtime.sendNativeMessage("reynard", {
    ...message,
    tabId: sender.tab ? sender.tab.id : null,
  });
});
