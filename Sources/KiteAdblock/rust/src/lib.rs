//! A small C API over Brave's adblock-rust for Kite.
//!
//! Every function catches panics, so a bad filter or URL can never unwind into
//! the browser; failures come back as null or `false`. Strings returned to C are
//! NUL-terminated UTF-8 owned by Rust: free them with `ka_string_free`.

use adblock::Engine;
use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;
use adblock::resources::{PermissionMask, Resource};
use std::collections::HashSet;
use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::ptr;
use std::slice;

/// An adblock engine. Immutable once built, so it's safe to share between
/// threads (CEF's IO thread checks requests while the UI thread asks for CSS).
pub struct KAEngine(Engine);

const _: () = {
    const fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<KAEngine>();
};

/// The verdict for one network request.
#[repr(C)]
pub struct KACheckResult {
    /// Block the request (an exception didn't override the match).
    pub blocked: bool,
    /// A blocking rule matched, even if an exception then allowed the request.
    pub matched: bool,
    /// An exception (`@@`) rule matched.
    pub exception: bool,
    /// `$important`: block regardless of exceptions.
    pub important: bool,
    /// A `data:` URL to serve instead of the resource (`$redirect`), or null.
    pub redirect: *mut c_char,
    /// The URL with tracking parameters removed (`$removeparam`), or null.
    pub rewritten_url: *mut c_char,
}

fn guard<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(fallback)
}

unsafe fn str_arg<'a>(s: *const c_char) -> Option<&'a str> {
    if s.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(s) }.to_str().ok()
}

unsafe fn bytes_arg<'a>(data: *const u8, len: usize) -> &'a [u8] {
    if data.is_null() || len == 0 {
        return &[];
    }
    unsafe { slice::from_raw_parts(data, len) }
}

fn to_c_string(s: impl Into<Vec<u8>>) -> *mut c_char {
    CString::new(s).map(CString::into_raw).unwrap_or(ptr::null_mut())
}

/// One filter list passed in from C.
#[repr(C)]
pub struct KAList {
    /// UTF-8 list text; doesn't need a NUL terminator.
    pub text: *const u8,
    pub len: usize,
    /// Lets the list use uBlock Origin's `trusted-*` scriptlets. Only for uBO's own lists.
    pub trusted: bool,
}

fn filter_set(lists: *const KAList, count: usize, debug: bool) -> FilterSet {
    let mut set = FilterSet::new(debug);
    if lists.is_null() {
        return set;
    }
    for list in unsafe { slice::from_raw_parts(lists, count) } {
        let text = String::from_utf8_lossy(unsafe { bytes_arg(list.text, list.len) }).into_owned();
        let permissions = PermissionMask::from_bits(if list.trusted { KA_TRUSTED } else { 0 });
        set.add_filter_list(text, ParseOptions { permissions, ..ParseOptions::default() });
    }
    set
}

/// The permission bit uBlock Origin's `requiresTrust` scriptlets carry.
pub const KA_TRUSTED: u8 = 1;

/// Builds an engine from `count` filter lists.
/// Takes about a second for EasyList + EasyPrivacy + uBlock filters, so call it
/// off the main thread.
#[unsafe(no_mangle)]
pub extern "C" fn ka_engine_new(lists: *const KAList, count: usize) -> *mut KAEngine {
    guard(ptr::null_mut(), || {
        let engine = Engine::new_with_filter_set(filter_set(lists, count, false));
        Box::into_raw(Box::new(KAEngine(engine)))
    })
}

/// Rebuilds an engine from `ka_engine_serialize` output. Null if the bytes came
/// from an incompatible adblock-rust version or are corrupt: rebuild from the lists then.
#[unsafe(no_mangle)]
pub extern "C" fn ka_engine_deserialize(data: *const u8, len: usize) -> *mut KAEngine {
    guard(ptr::null_mut(), || {
        let mut engine = Engine::default();
        match engine.deserialize(unsafe { bytes_arg(data, len) }) {
            Ok(()) => Box::into_raw(Box::new(KAEngine(engine))),
            Err(_) => ptr::null_mut(),
        }
    })
}

/// The engine's compiled rules, for caching on disk. Resources aren't included;
/// pass them to `ka_engine_use_resources` again after deserializing.
#[unsafe(no_mangle)]
pub extern "C" fn ka_engine_serialize(engine: *const KAEngine, out_len: *mut usize) -> *mut u8 {
    guard(ptr::null_mut(), || {
        let Some(engine) = (unsafe { engine.as_ref() }) else { return ptr::null_mut() };
        let bytes = engine.0.serialize().into_boxed_slice();
        if !out_len.is_null() {
            unsafe { *out_len = bytes.len() };
        }
        Box::into_raw(bytes) as *mut u8
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn ka_bytes_free(data: *mut u8, len: usize) {
    if !data.is_null() {
        drop(unsafe { Box::from_raw(ptr::slice_from_raw_parts_mut(data, len)) });
    }
}

/// Sets the scriptlets and redirect bodies (`$redirect`, `##+js(...)`) from a JSON
/// array of adblock-rust `Resource`s. Call before sharing the engine between threads.
#[unsafe(no_mangle)]
pub extern "C" fn ka_engine_use_resources(engine: *mut KAEngine, json: *const u8, len: usize) -> bool {
    guard(false, || {
        let Some(engine) = (unsafe { engine.as_mut() }) else { return false };
        match serde_json::from_slice::<Vec<Resource>>(unsafe { bytes_arg(json, len) }) {
            Ok(resources) => {
                engine.0.use_resources(resources);
                true
            }
            Err(_) => false,
        }
    })
}

/// Checks one request. `request_type` is a webRequest type: "document", "subdocument",
/// "script", "stylesheet", "image", "media", "font", "xmlhttprequest", "fetch",
/// "ping", "websocket", "other". Free the result with `ka_check_result_free`.
#[unsafe(no_mangle)]
pub extern "C" fn ka_engine_check(
    engine: *const KAEngine,
    url: *const c_char,
    source_url: *const c_char,
    request_type: *const c_char,
) -> KACheckResult {
    let empty = || KACheckResult {
        blocked: false,
        matched: false,
        exception: false,
        important: false,
        redirect: ptr::null_mut(),
        rewritten_url: ptr::null_mut(),
    };
    guard(empty(), || {
        let (Some(engine), Some(url)) = (unsafe { engine.as_ref() }, unsafe { str_arg(url) }) else {
            return empty();
        };
        let source = unsafe { str_arg(source_url) }.unwrap_or("");
        let kind = unsafe { str_arg(request_type) }.unwrap_or("other");
        let Ok(request) = Request::new(url, source, kind, "get") else { return empty() };
        let result = engine.0.check_network_request(&request);
        KACheckResult {
            blocked: result.should_block(),
            matched: result.filter.is_some(),
            exception: result.exception.is_some(),
            important: result.important,
            redirect: result.redirect.map(to_c_string).unwrap_or(ptr::null_mut()),
            rewritten_url: result.rewritten_url.map(to_c_string).unwrap_or(ptr::null_mut()),
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn ka_check_result_free(result: *mut KACheckResult) {
    let Some(result) = (unsafe { result.as_mut() }) else { return };
    ka_string_free(result.redirect);
    ka_string_free(result.rewritten_url);
    result.redirect = ptr::null_mut();
    result.rewritten_url = ptr::null_mut();
}

/// What to inject into a page before it loads, as JSON:
/// `{"hide_selectors": [...], "procedural_actions": [...], "exceptions": [...],
///   "injected_script": "...", "generichide": false}`.
#[unsafe(no_mangle)]
pub extern "C" fn ka_engine_url_cosmetic_resources(engine: *const KAEngine, url: *const c_char) -> *mut c_char {
    guard(ptr::null_mut(), || {
        let (Some(engine), Some(url)) = (unsafe { engine.as_ref() }, unsafe { str_arg(url) }) else {
            return ptr::null_mut();
        };
        let resources = engine.0.url_cosmetic_resources(url);
        serde_json::to_string(&resources).map(to_c_string).unwrap_or(ptr::null_mut())
    })
}

/// Generic hide selectors for classes and ids seen on a page. All three inputs
/// are JSON arrays of strings; `exceptions` comes from the cosmetic resources.
/// Returns a JSON array of selectors.
#[unsafe(no_mangle)]
pub extern "C" fn ka_engine_hidden_class_id_selectors(
    engine: *const KAEngine,
    classes_json: *const c_char,
    ids_json: *const c_char,
    exceptions_json: *const c_char,
) -> *mut c_char {
    guard(ptr::null_mut(), || {
        let Some(engine) = (unsafe { engine.as_ref() }) else { return ptr::null_mut() };
        let parse = |s: *const c_char| -> Vec<String> {
            unsafe { str_arg(s) }.and_then(|s| serde_json::from_str(s).ok()).unwrap_or_default()
        };
        let exceptions: HashSet<String> = parse(exceptions_json).into_iter().collect();
        let selectors = engine.0.hidden_class_id_selectors(parse(classes_json), parse(ids_json), &exceptions);
        serde_json::to_string(&selectors).map(to_c_string).unwrap_or(ptr::null_mut())
    })
}

/// Converts filter lists to a WebKit content-blocker JSON (for WKContentRuleListStore).
/// Rules that WebKit can't express are dropped; `out_rule_count` gets the count kept.
#[unsafe(no_mangle)]
pub extern "C" fn ka_content_blocking_json(
    lists: *const KAList,
    count: usize,
    out_rule_count: *mut usize,
) -> *mut c_char {
    guard(ptr::null_mut(), || {
        let Ok((rules, _)) = filter_set(lists, count, true).into_content_blocking() else {
            return ptr::null_mut();
        };
        if !out_rule_count.is_null() {
            unsafe { *out_rule_count = rules.len() };
        }
        serde_json::to_string(&rules).map(to_c_string).unwrap_or(ptr::null_mut())
    })
}

/// Builds redirect resources from uBlock Origin's `web_accessible_resources` folder and
/// its `redirect-resources.js` index. Returns a JSON array of `Resource`s.
#[unsafe(no_mangle)]
pub extern "C" fn ka_assemble_redirect_resources(directory: *const c_char, index_path: *const c_char) -> *mut c_char {
    guard(ptr::null_mut(), || {
        let (Some(directory), Some(index)) = (unsafe { str_arg(directory) }, unsafe { str_arg(index_path) }) else {
            return ptr::null_mut();
        };
        let resources = adblock::resources::resource_assembler::assemble_web_accessible_resources(
            Path::new(directory),
            Path::new(index),
        );
        serde_json::to_string(&resources).map(to_c_string).unwrap_or(ptr::null_mut())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn ka_engine_free(engine: *mut KAEngine) {
    if !engine.is_null() {
        drop(unsafe { Box::from_raw(engine) });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn ka_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}
