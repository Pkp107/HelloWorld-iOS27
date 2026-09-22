// Workspace Frida guest bridge
//
// Load this script from a Frida Gadget configured inside a LiveContainer guest.
// Set WORKSPACE_GUEST_MCP_URL to the Workspace bridge's /guest/ URL and set
// WORKSPACE_GUEST_MCP_TOKEN to the bearer token shown by Workspace. The bridge
// polls queued evaluations, executes them in the Gadget runtime, and forwards
// console output back to Workspace.
//
// Frida Gadget does not provide fetch(). This script uses NSURLSession through
// the guest's Objective-C runtime, so it is intended for iOS Objective-C/Swift
// guests. For a non-ObjC guest, use an equivalent HTTP adapter in the Gadget.

'use strict';

const BASE_URL = (globalThis.WORKSPACE_GUEST_MCP_URL || 'http://127.0.0.1:27042/').replace(/\/+$/, '') + '/';
const TOKEN = globalThis.WORKSPACE_GUEST_MCP_TOKEN || '';
const POLL_INTERVAL_MS = 250;

function request(path, method, payload, callback) {
  if (!ObjC.available) {
    callback(new Error('Objective-C runtime is unavailable'), null);
    return;
  }

  const url = ObjC.classes.NSURL.URLWithString_(BASE_URL + path.replace(/^\/+/, ''));
  const request = ObjC.classes.NSMutableURLRequest.requestWithURL_(url);
  request.setHTTPMethod_(method);
  request.setValue_forHTTPHeaderField_('application/json', 'Content-Type');
  if (TOKEN.length > 0) {
    request.setValue_forHTTPHeaderField_('Bearer ' + TOKEN, 'Authorization');
  }
  if (payload !== null) {
    const body = ObjC.classes.NSString.stringWithString_(JSON.stringify(payload))
      .dataUsingEncoding_(4); // NSUTF8StringEncoding
    request.setHTTPBody_(body);
  }

  const session = ObjC.classes.NSURLSession.sharedSession();
  const delegate = new ObjC.Block({
    retType: 'void',
    argTypes: ['object', 'object', 'object'],
    implementation: function (data, _response, error) {
      if (error) {
        callback(new Error(error.localizedDescription().toString()), null);
        return;
      }
      const text = data
        ? ObjC.classes.NSString.alloc().initWithData_encoding_(data, 4).toString()
        : '';
      try {
        callback(null, text.length > 0 ? JSON.parse(text) : {});
      } catch (parseError) {
        callback(parseError, null);
      }
    }
  });
  session.dataTaskWithRequest_completionHandler_(request, delegate).resume();
}

function log(message, level) {
  request('log', 'POST', { message: String(message), level: level || 'info' }, function () {});
}

function complete(item, result, error) {
  request('result', 'POST', {
    id: item.id,
    result: result === null ? null : String(result),
    error: error === null ? null : String(error)
  }, function () {});
}

function completeControl(command, result, error) {
  request('control/result', 'POST', {
    id: command.id,
    result: result === null ? null : (typeof result === 'string' ? result : JSON.stringify(result)),
    error: error === null ? null : String(error)
  }, function () {});
}

function firstWindow() {
  const application = ObjC.classes.UIApplication.sharedApplication();
  const windows = application.windows();
  for (let index = 0; index < windows.count(); index += 1) {
    const candidate = windows.objectAtIndex_(index);
    if (!candidate.isHidden() && candidate.alpha() > 0.01) return candidate;
  }
  return windows.count() > 0 ? windows.objectAtIndex_(0) : null;
}

function viewAtPath(path) {
  let view = firstWindow();
  if (!view) return null;
  const parts = String(path || '').split('.').filter(function (part) { return part.length > 0; });
  // The first component identifies the root. Tokens produced by Workspace are
  // snapshot-id.0.1.2, so skip the root component and follow subview indexes.
  for (let index = 1; index < parts.length; index += 1) {
    const childIndex = Number(parts[index]);
    if (!Number.isInteger(childIndex) || childIndex < 0) return null;
    const children = view.subviews();
    if (childIndex >= children.count()) return null;
    view = children.objectAtIndex_(childIndex);
  }
  return view;
}

function viewForCommand(command) {
  if (!command.elementToken) return null;
  const token = String(command.elementToken);
  const separator = token.indexOf('.');
  return separator >= 0 ? viewAtPath(token.slice(separator + 1)) : null;
}

// Return a compact semantic description without relying on private UIKit APIs.
// The host snapshot remains authoritative for tokens; this is an additional
// guest-side observation for apps whose view hierarchy is only visible to the
// instrumented process.
function viewDescription(view, root, depth, budget) {
  if (!view || budget.count >= budget.max || depth > budget.maxDepth) return null;
  budget.count += 1;
  const frame = view.convertRect_toView_(view.bounds(), root);
  const value = {
    type: view.$className || String(view.$className || 'UIView'),
    frame: { x: frame.origin.x, y: frame.origin.y, width: frame.size.width, height: frame.size.height },
    visible: !view.isHidden() && Number(view.alpha()) > 0.01,
    userInteractionEnabled: !!view.isUserInteractionEnabled()
  };
  try {
    const label = view.accessibilityLabel();
    const identifier = view.accessibilityIdentifier();
    const valueText = view.accessibilityValue();
    const hint = view.accessibilityHint();
    if (label) value.label = label.toString();
    if (identifier) value.identifier = identifier.toString();
    if (valueText) value.value = valueText.toString();
    if (hint) value.hint = hint.toString();
    if (view.isAccessibilityElement()) value.accessibilityElement = true;
  } catch (_) {}
  if (view.respondsToSelector_('isEnabled')) {
    try { value.enabled = !!view.isEnabled(); } catch (_) {}
  }
  if (view.respondsToSelector_('currentTitle')) {
    try { const title = view.currentTitle(); if (title) value.title = title.toString(); } catch (_) {}
  }
  const children = [];
  const subviews = view.subviews();
  for (let index = 0; index < subviews.count() && budget.count < budget.max; index += 1) {
    const child = viewDescription(subviews.objectAtIndex_(index), root, depth + 1, budget);
    if (child) children.push(child);
  }
  if (children.length > 0) value.children = children;
  return value;
}

function firstResponderInView(view) {
  if (!view) return null;
  if (view.isFirstResponder && view.isFirstResponder()) return view;
  const children = view.subviews();
  for (let index = 0; index < children.count(); index += 1) {
    const found = firstResponderInView(children.objectAtIndex_(index));
    if (found) return found;
  }
  return null;
}

function responderDescription(view) {
  if (!view) return { focused: false };
  const value = { focused: true, type: view.$className || 'UIResponder' };
  try {
    const label = view.accessibilityLabel();
    const identifier = view.accessibilityIdentifier();
    if (label) value.label = label.toString();
    if (identifier) value.identifier = identifier.toString();
  } catch (_) {}
  if (view.respondsToSelector_('text')) {
    try { const text = view.text(); if (text) value.text = text.toString(); } catch (_) {}
  }
  return value;
}

function guestAccessibilitySnapshot(command) {
  const root = firstWindow();
  if (!root) throw new Error('No visible guest window is available.');
  const payload = command.payload || {};
  const budget = { count: 0, max: Math.min(500, Math.max(1, Number(payload.max_nodes) || 250)), maxDepth: Math.min(20, Math.max(1, Number(payload.max_depth) || 10)) };
  return { tree: viewDescription(root, root, 0, budget), node_count: budget.count, truncated: budget.count >= budget.max };
}

function guestFocus(command) {
  const root = firstWindow();
  const responder = firstResponderInView(root);
  if (command.payload && command.payload.action === 'resign') {
    if (responder && responder.resignFirstResponder()) return { focused: false, action: 'resign' };
    return { focused: false, action: 'resign' };
  }
  return responderDescription(responder);
}

function guestKeyboard(command) {
  const application = ObjC.classes.UIApplication.sharedApplication();
  const action = String(command.payload && command.payload.action || 'state').toLowerCase();
  if (action === 'hide') {
    application.sendAction_to_from_forEvent_('resignFirstResponder', null, null, null);
    return { visible: false, action: 'hide' };
  }
  if (action === 'show') {
    const responder = firstResponderInView(firstWindow());
    if (!responder || !responder.becomeFirstResponder()) throw new Error('No text responder can show the keyboard.');
    return { visible: true, action: 'show' };
  }
  return { visible: !!firstResponderInView(firstWindow()), action: 'state' };
}

function guestClipboard(command) {
  const pasteboard = ObjC.classes.UIPasteboard.generalPasteboard();
  const action = String(command.payload && command.payload.action || 'get').toLowerCase();
  if (action === 'clear') { pasteboard.setItems_([]); return { cleared: true }; }
  if (action === 'set') {
    const text = String(command.payload && command.payload.text || '');
    if (text.length > 1024 * 1024) throw new Error('Clipboard text exceeds the 1 MiB limit.');
    pasteboard.setString_(text);
    return { text: text, length: text.length };
  }
  const text = pasteboard.string();
  return { text: text ? text.toString() : null };
}

function guestRuntimeInfo() {
  const processInfo = ObjC.classes.NSProcessInfo.processInfo();
  const application = ObjC.classes.UIApplication.sharedApplication();
  const bundle = ObjC.classes.NSBundle.mainBundle();
  return {
    pid: ObjC.classes.NSProcessInfo.processInfo().processIdentifier(),
    bundle_identifier: bundle.bundleIdentifier() ? bundle.bundleIdentifier().toString() : null,
    os_version: processInfo.operatingSystemVersionString().toString(),
    physical_memory: Number(processInfo.physicalMemory()),
    application_state: Number(application.applicationState()),
    timestamp: Date.now()
  };
}

function sandboxPath(input) {
  const home = ObjC.classes.NSFileManager.defaultManager().homeDirectoryForCurrentUser().path().toString();
  const candidate = String(input || '');
  const absolute = candidate.charAt(0) === '/' ? candidate : home + '/' + candidate;
  // Normalize through NSString and ensure the result stays inside the guest.
  const normalized = ObjC.classes.NSString.stringWithString_(absolute).stringByStandardizingPath().toString();
  if (normalized !== home && normalized.indexOf(home + '/') !== 0) throw new Error('Path is outside the guest sandbox.');
  return normalized;
}

function guestFilesystem(command) {
  const fm = ObjC.classes.NSFileManager.defaultManager();
  const action = String(command.payload && command.payload.action || 'stat').toLowerCase();
  const path = sandboxPath(command.payload && command.payload.path || '');
  if (action === 'list') {
    const entries = fm.contentsOfDirectoryAtPath_error_(path, null);
    const output = [];
    if (entries) for (let index = 0; index < entries.count() && index < 1000; index += 1) output.push(entries.objectAtIndex_(index).toString());
    return { path: path, entries: output };
  }
  if (action === 'read') {
    const data = ObjC.classes.NSData.dataWithContentsOfFile_(path);
    if (!data || Number(data.length()) > 2 * 1024 * 1024) throw new Error('File is unavailable or exceeds the 2 MiB read limit.');
    const text = ObjC.classes.NSString.alloc().initWithData_encoding_(data, 4);
    if (!text) throw new Error('File is not UTF-8 text.');
    return { path: path, text: text.toString(), bytes: Number(data.length()) };
  }
  if (action === 'write') {
    const text = String(command.payload && command.payload.text || '');
    if (text.length > 2 * 1024 * 1024) throw new Error('Text exceeds the 2 MiB write limit.');
    const data = ObjC.classes.NSString.stringWithString_(text).dataUsingEncoding_(4);
    if (!data || !data.writeToFile_atomically_(path, true)) throw new Error('Unable to write file.');
    return { path: path, bytes: text.length };
  }
  const attributes = fm.attributesOfItemAtPath_error_(path, null);
  if (!attributes) throw new Error('Path does not exist.');
  const type = attributes.objectForKey_('NSFileType');
  const size = attributes.objectForKey_('NSFileSize');
  return { path: path, is_directory: !!type && type.toString().indexOf('Directory') >= 0, size: size ? Number(size) : 0 };
}

function performTap(command) {
  let view = viewForCommand(command);
  if (!view && command.payload && Number.isFinite(Number(command.payload.x)) && Number.isFinite(Number(command.payload.y))) {
    const window = firstWindow();
    if (window) view = window.hitTest_withEvent_({
      x: Number(command.payload.x),
      y: Number(command.payload.y)
    }, null);
  }
  if (view) {
    if (view.accessibilityActivate) {
      if (view.accessibilityActivate()) return 'accessibility activation applied';
    }
    if (view.sendActionsForControlEvents_) {
      view.sendActionsForControlEvents_(64); // UIControlEventTouchUpInside
      return 'control action sent';
    }
  }
  throw new Error('The guest element could not be activated. Install the bridge in the guest and refresh guest_state.');
}

function performDoubleTap(command) {
  const view = viewForCommand(command);
  if (!view) throw new Error('Double tap requires a current semantic element token.');
  if (view.accessibilityActivate && view.accessibilityActivate()) return 'accessibility activation applied';
  if (view.respondsToSelector_('sendActionsForControlEvents_')) {
    view.sendActionsForControlEvents_(64);
    view.sendActionsForControlEvents_(64);
    return 'control action sent twice';
  }
  throw new Error('The guest element cannot receive a double tap.');
}

function performLongPress(command) {
  const view = viewForCommand(command);
  if (!view) throw new Error('Long press requires a current semantic element token.');
  const handlers = globalThis.WORKSPACE_GUEST_CONTROL_HANDLERS || {};
  if (typeof handlers.long_press === 'function') return handlers.long_press(command.payload || {}, command.elementToken || null, command.snapshotID);
  throw new Error('Long press requires an opted-in guest handler.');
}

function performSetText(command) {
  const text = command.payload && typeof command.payload.text === 'string' ? command.payload.text : '';
  const view = viewForCommand(command) || firstResponderInView(firstWindow());
  if (!view || !view.respondsToSelector_('setText:')) throw new Error('No text control is focused.');
  if (text.length > 1024 * 1024) throw new Error('Text exceeds the 1 MiB limit.');
  view.setText_(text);
  return { text: text, length: text.length };
}

function performScroll(command) {
  const view = viewForCommand(command);
  if (!view || !view.isKindOfClass_(ObjC.classes.UIScrollView)) throw new Error('Scroll requires a UIScrollView element.');
  const payload = command.payload || {};
  const offset = view.contentOffset();
  const x = Number.isFinite(Number(payload.x)) ? Number(payload.x) : offset.x;
  const y = Number.isFinite(Number(payload.y)) ? Number(payload.y) : offset.y;
  view.setContentOffset_animated_({ x: x, y: y }, payload.animated !== false);
  return { x: x, y: y };
}

function performType(command) {
  const text = command.payload && typeof command.payload.text === 'string' ? command.payload.text : '';
  if (text.length === 0) throw new Error('Text is empty.');
  const application = ObjC.classes.UIApplication.sharedApplication();
  // UIApplication's responder action is the supported way to insert text into
  // the active text editor without constructing private UITouch objects.
  application.sendAction_to_from_forEvent_('insertText:', null, text, null);
  return 'text insertion requested';
}

function performKey(command) {
  const key = String(command.payload && command.payload.key || '').toLowerCase();
  const application = ObjC.classes.UIApplication.sharedApplication();
  if (key === 'return' || key === 'escape' || key === 'back' || key === 'home') {
    application.sendAction_to_from_forEvent_('resignFirstResponder', null, null, null);
    return key + ' action sent';
  }
  if (key === 'delete' || key === 'backspace') {
    application.sendAction_to_from_forEvent_('deleteBackward:', null, null, null);
    return 'delete action sent';
  }
  throw new Error('Unsupported key. Allowed keys are return, escape, back, home, delete, and backspace.');
}

function performSwipe(command) {
  const view = viewForCommand(command);
  if (view && view.isKindOfClass_(ObjC.classes.UIScrollView)) {
    const from = command.payload && command.payload.from;
    const to = command.payload && command.payload.to;
    if (from && to && from.length >= 2 && to.length >= 2) {
      const offset = view.contentOffset();
      const size = view.bounds().size;
      const dx = (Number(from[0]) - Number(to[0])) * size.width;
      const dy = (Number(from[1]) - Number(to[1])) * size.height;
      view.setContentOffset_animated_({
        x: offset.x + dx,
        y: offset.y + dy
      }, true);
      return 'scroll offset updated';
    }
  }
  throw new Error('Swipe requires a guest UIScrollView or an instrumented gesture handler.');
}

function executeControl(command) {
  try {
    const payload = typeof command.payload === 'string' ? JSON.parse(command.payload || '{}') : (command.payload || {});
    command.payload = payload;
    const customHandlers = globalThis.WORKSPACE_GUEST_CONTROL_HANDLERS || {};
    const customHandler = customHandlers[command.kind];
    if (typeof customHandler === 'function') {
      const customResult = customHandler(payload, command.elementToken || null, command.snapshotID);
      completeControl(command, customResult === undefined ? 'ok' : customResult, null);
      log('Guest control completed: ' + command.kind, 'control');
      return;
    }
    let result;
    if (command.kind === 'tap') result = performTap(command);
    else if (command.kind === 'double_tap') result = performDoubleTap(command);
    else if (command.kind === 'long_press') result = performLongPress(command);
    else if (command.kind === 'swipe') result = performSwipe(command);
    else if (command.kind === 'scroll') result = performScroll(command);
    else if (command.kind === 'type') result = performType(command);
    else if (command.kind === 'set_text') result = performSetText(command);
    else if (command.kind === 'key') result = performKey(command);
    else if (command.kind === 'accessibility_snapshot') result = guestAccessibilitySnapshot(command);
    else if (command.kind === 'focus') result = guestFocus(command);
    else if (command.kind === 'keyboard') result = guestKeyboard(command);
    else if (command.kind === 'clipboard') result = guestClipboard(command);
    else if (command.kind === 'runtime_info' || command.kind === 'metrics') result = guestRuntimeInfo();
    else if (command.kind === 'filesystem') result = guestFilesystem(command);
    else throw new Error('Unsupported guest control command: ' + command.kind);
    completeControl(command, result, null);
    log('Guest control completed: ' + command.id, 'control');
  } catch (error) {
    completeControl(command, null, error.stack || error.toString());
    log('Guest control failed: ' + error, 'error');
  }
}

function execute(item) {
  try {
    // The code is supplied by the authenticated Workspace MCP client. The
    // result is deliberately stringified so it can cross the JSON boundary.
    const value = eval(item.code);
    complete(item, value === undefined ? 'undefined' : JSON.stringify(value), null);
    log('Frida evaluation completed: ' + item.id, 'result');
  } catch (error) {
    complete(item, null, error.stack || error.toString());
    log('Frida evaluation failed: ' + error, 'error');
  }
}

function poll() {
  request('pending', 'GET', null, function (error, response) {
    if (error) {
      setTimeout(poll, POLL_INTERVAL_MS * 4);
      return;
    }
    (response.evaluations || []).forEach(execute);
    request('control/pending', 'GET', null, function (controlError, controlResponse) {
      if (!controlError) (controlResponse.commands || []).forEach(executeControl);
      setTimeout(poll, POLL_INTERVAL_MS);
    });
  });
}

const originalLog = console.log;
console.log = function () {
  const message = Array.prototype.slice.call(arguments).map(String).join(' ');
  originalLog.apply(console, arguments);
  log(message, 'console');
};

log('Workspace Frida bridge connected', 'system');
poll();
