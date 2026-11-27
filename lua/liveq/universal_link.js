// Opens a URL as a universal link only: in the app that claims it (its associated domains), never in the browser.
// Prints "ok", or why not (no app claims it, or a timeout). macOS only.
//
//   osascript -l JavaScript universal_link.js URL
//
// `open URL` always goes to the default browser; NSWorkspace with requiresUniversalLinks is how a link from outside
// reaches e.g. Outlook for Mac (the mail picker's alt-o, sources/notmuch.lua).
ObjC.import('AppKit')

function run(argv) {
  const cfg = $.NSWorkspaceOpenConfiguration.configuration
  cfg.requiresUniversalLinks = true
  let result = null
  $.NSWorkspace.sharedWorkspace.openURLConfigurationCompletionHandler($.NSURL.URLWithString(argv[0]), cfg, (app, err) => {
    result = err && !err.isNil() ? ObjC.unwrap(err.localizedDescription) : 'ok'
  })
  const until = Date.now() + 10000
  while (result === null && Date.now() < until) {
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.05))
  }
  return result || 'timeout'
}
