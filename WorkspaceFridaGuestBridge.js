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
    result: result === null ? null : String(result),
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
  if (key === 'return' || key === 'escape' || key === 'back') {
    application.sendAction_to_from_forEvent_('resignFirstResponder', null, null, null);
    return key + ' action sent';
  }
  throw new Error('Unsupported key. Allowed keys are return, escape, and back.');
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
    else if (command.kind === 'swipe') result = performSwipe(command);
    else if (command.kind === 'type') result = performType(command);
    else if (command.kind === 'key') result = performKey(command);
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
