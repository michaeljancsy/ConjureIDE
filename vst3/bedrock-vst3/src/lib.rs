//! **Bedrock** — a multi-track spectrum analyzer, packaged as two VST3 plugins in one module.
//!
//! * **Bedrock Track** goes on every channel you want to see. It measures the audio passing
//!   through and publishes a spectrum to a realm.
//! * **Bedrock Vision** goes on one track of its own. It owns the realm and draws every
//!   Track's spectrum layered into a single graph.
//!
//! Both are shipped from one factory so a single `.vst3` bundle installs the pair.

#![allow(non_upper_case_globals)]
#![allow(non_camel_case_types)]
#![allow(non_snake_case)]

use std::ffi::{c_void, CStr};

use vst3::{Class, ComWrapper, Steinberg::Vst::*, Steinberg::*};

pub mod boilerplate;
pub mod common;
mod platform;
pub mod track;
pub mod view;
pub mod vision;

use common::copy_cstring;
use track::Track;
use vision::Vision;

const VENDOR: &str = bedrock_core::VENDOR;
const URL: &str = "https://github.com/michaeljancsy/conjuredsp-application";
const EMAIL: &str = "";
const VERSION: &str = env!("CARGO_PKG_VERSION");

/// The VST3 SDK spells this as a C++ `#define`, so it is not in the generated bindings.
const AUDIO_MODULE_CLASS: &str = "Audio Module Class";

struct Factory;

impl Class for Factory {
    type Interfaces = (IPluginFactory3,);
}

/// The classes this module exposes, in the order the host enumerates them.
const CLASSES: [(&TUID, &str, &str); 2] = [
    (&Track::CID, "Bedrock Track", "Fx|Analyzer"),
    (&Vision::CID, "Bedrock Vision", "Fx|Analyzer"),
];

impl IPluginFactoryTrait for Factory {
    unsafe fn getFactoryInfo(&self, info: *mut PFactoryInfo) -> tresult {
        if info.is_null() {
            return kInvalidArgument;
        }
        let info = &mut *info;
        copy_cstring(VENDOR, &mut info.vendor);
        copy_cstring(URL, &mut info.url);
        copy_cstring(EMAIL, &mut info.email);
        info.flags = PFactoryInfo_::FactoryFlags_::kUnicode as int32;
        kResultOk
    }

    unsafe fn countClasses(&self) -> int32 {
        CLASSES.len() as int32
    }

    unsafe fn getClassInfo(&self, index: int32, info: *mut PClassInfo) -> tresult {
        let Some((cid, name, _)) = usize::try_from(index).ok().and_then(|i| CLASSES.get(i)) else {
            return kInvalidArgument;
        };
        if info.is_null() {
            return kInvalidArgument;
        }
        let info = &mut *info;
        info.cid = **cid;
        info.cardinality = PClassInfo_::ClassCardinality_::kManyInstances as int32;
        copy_cstring(AUDIO_MODULE_CLASS, &mut info.category);
        copy_cstring(name, &mut info.name);
        kResultOk
    }

    unsafe fn createInstance(
        &self,
        cid: FIDString,
        iid: FIDString,
        obj: *mut *mut c_void,
    ) -> tresult {
        if cid.is_null() || iid.is_null() || obj.is_null() {
            return kInvalidArgument;
        }
        let requested = *(cid as *const TUID);
        let instance = if requested == Track::CID {
            ComWrapper::new(Track::new()).to_com_ptr::<FUnknown>()
        } else if requested == Vision::CID {
            ComWrapper::new(Vision::new()).to_com_ptr::<FUnknown>()
        } else {
            None
        };

        match instance {
            Some(instance) => {
                let ptr = instance.as_ptr();
                ((*(*ptr).vtbl).queryInterface)(ptr, iid as *mut TUID, obj)
            }
            None => kNoInterface,
        }
    }
}

impl IPluginFactory2Trait for Factory {
    unsafe fn getClassInfo2(&self, index: int32, info: *mut PClassInfo2) -> tresult {
        let Some((cid, name, subcategories)) =
            usize::try_from(index).ok().and_then(|i| CLASSES.get(i))
        else {
            return kInvalidArgument;
        };
        if info.is_null() {
            return kInvalidArgument;
        }
        let info = &mut *info;
        info.cid = **cid;
        info.cardinality = PClassInfo_::ClassCardinality_::kManyInstances as int32;
        copy_cstring(AUDIO_MODULE_CLASS, &mut info.category);
        copy_cstring(name, &mut info.name);
        // Single-component effect: one object serves as component and controller.
        info.classFlags = Vst::ComponentFlags_::kSimpleModeSupported as uint32;
        copy_cstring(subcategories, &mut info.subCategories);
        copy_cstring(VENDOR, &mut info.vendor);
        copy_cstring(VERSION, &mut info.version);
        copy_cstring(sdk_version(), &mut info.sdkVersion);
        kResultOk
    }
}

impl IPluginFactory3Trait for Factory {
    unsafe fn getClassInfoUnicode(&self, index: int32, info: *mut PClassInfoW) -> tresult {
        let Some((cid, name, subcategories)) =
            usize::try_from(index).ok().and_then(|i| CLASSES.get(i))
        else {
            return kInvalidArgument;
        };
        if info.is_null() {
            return kInvalidArgument;
        }
        let info = &mut *info;
        info.cid = **cid;
        info.cardinality = PClassInfo_::ClassCardinality_::kManyInstances as int32;
        copy_cstring(AUDIO_MODULE_CLASS, &mut info.category);
        common::copy_wstring(name, &mut info.name);
        info.classFlags = Vst::ComponentFlags_::kSimpleModeSupported as uint32;
        copy_cstring(subcategories, &mut info.subCategories);
        common::copy_wstring(VENDOR, &mut info.vendor);
        common::copy_wstring(VERSION, &mut info.version);
        common::copy_wstring(sdk_version(), &mut info.sdkVersion);
        kResultOk
    }

    unsafe fn setHostContext(&self, _context: *mut FUnknown) -> tresult {
        kResultOk
    }
}

/// The VST3 SDK version the bindings were generated against.
fn sdk_version() -> &'static str {
    // Safety: the binding is a NUL-terminated literal.
    unsafe { CStr::from_ptr(SDKVersionString) }
        .to_str()
        .unwrap_or("VST 3")
}

// ---------------------------------------------------------------------------------------------
// Module entry points
// ---------------------------------------------------------------------------------------------

#[cfg(target_os = "windows")]
#[no_mangle]
extern "system" fn InitDll() -> bool {
    true
}

#[cfg(target_os = "windows")]
#[no_mangle]
extern "system" fn ExitDll() -> bool {
    true
}

#[cfg(target_os = "macos")]
#[no_mangle]
extern "system" fn bundleEntry(_bundle_ref: *mut c_void) -> bool {
    true
}

#[cfg(target_os = "macos")]
#[no_mangle]
extern "system" fn bundleExit() -> bool {
    true
}

#[cfg(target_os = "linux")]
#[no_mangle]
extern "system" fn ModuleEntry(_library_handle: *mut c_void) -> bool {
    true
}

#[cfg(target_os = "linux")]
#[no_mangle]
extern "system" fn ModuleExit() -> bool {
    true
}

#[no_mangle]
extern "system" fn GetPluginFactory() -> *mut IPluginFactory {
    match ComWrapper::new(Factory).to_com_ptr::<IPluginFactory>() {
        Some(factory) => factory.into_raw(),
        None => std::ptr::null_mut(),
    }
}
