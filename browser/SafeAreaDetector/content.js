// Reynard Safe Area Detector — content script
//
// Relays through the background script rather than calling
// runtime.sendNativeMessage() directly from here — a known, reported
// GeckoView bug (mozilla/geckoview#220) means native messages sent
// straight from a content script never actually resolve, even though
// the identical call works fine from a background script. This
// internal runtime.sendMessage() call is ordinary extension messaging,
// not native messaging, so it isn't affected by that bug at all.
browser.runtime.sendMessage({
  test: true,
  url: window.location.href,
});
