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
    setTimeout(poll, POLL_INTERVAL_MS);
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
