#!/usr/bin/env python3
# Copyright (c) 2026 Pedro Shakour
# SPDX-License-Identifier: Apache-2.0
"""Create a minimal, runnable iOS Xcode project for a phone workstream."""

from __future__ import annotations

import os
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Mapping


TARGET_NAME = "WorkstreamApp"


def projects_root(env: Mapping[str, str] = os.environ) -> Path:
    configured = env.get("GROK_PROJECTS_ROOT", "").strip()
    return Path(configured).expanduser() if configured else Path.home() / ".projects"


def _slug(value: str) -> str:
    cleaned = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return cleaned[:40] or "ios-app"


def create_workstream_project(
    name_hint: str = "ios-app",
    env: Mapping[str, str] = os.environ,
) -> Path:
    root = projects_root(env).resolve()
    root.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    directory = root / f"{_slug(name_hint)}-{timestamp}-{uuid.uuid4().hex[:6]}"
    source = directory / TARGET_NAME
    project = directory / f"{TARGET_NAME}.xcodeproj"
    source.mkdir(parents=True)
    project.mkdir()

    bundle_suffix = uuid.uuid4().hex[:12]
    (source / f"{TARGET_NAME}.swift").write_text(APP_SOURCE, encoding="utf-8")
    (source / "ContentView.swift").write_text(CONTENT_VIEW_SOURCE, encoding="utf-8")
    (project / "project.pbxproj").write_text(
        PROJECT_FILE.replace("__BUNDLE_SUFFIX__", bundle_suffix),
        encoding="utf-8",
    )
    (directory / "README.md").write_text(
        "# iOS workstream\n\nThis project was created by Grok Build for a phone workstream.\n",
        encoding="utf-8",
    )
    return directory


APP_SOURCE = """import SwiftUI

@main
struct WorkstreamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
"""


CONTENT_VIEW_SOURCE = """import SwiftUI

struct ContentView: View {
    var body: some View {
        ContentUnavailableView(
            "Ready to build",
            systemImage: "hammer",
            description: Text("Describe the iOS app you want from your phone.")
        )
    }
}

#Preview {
    ContentView()
}
"""


PROJECT_FILE = r'''// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {};
	objectVersion = 77;
	objects = {

/* Begin PBXFileReference section */
		000000000000000000000120 /* WorkstreamApp.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = WorkstreamApp.app; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		000000000000000000000010 /* WorkstreamApp */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = WorkstreamApp;
			sourceTree = "<group>";
		};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		000000000000000130000000 /* Frameworks */ = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		000000000000000000000001 = {
			isa = PBXGroup;
			children = (
				000000000000000000000010 /* WorkstreamApp */,
				000000000000000000000020 /* Products */,
			);
			sourceTree = "<group>";
		};
		000000000000000000000020 /* Products */ = {
			isa = PBXGroup;
			children = (000000000000000000000120 /* WorkstreamApp.app */,);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		000000000000000100000000 /* WorkstreamApp */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = 000000000000000110000000;
			buildPhases = (
				000000000000000120000000 /* Sources */,
				000000000000000130000000 /* Frameworks */,
				000000000000000140000000 /* Resources */,
			);
			buildRules = ();
			fileSystemSynchronizedGroups = (000000000000000000000010 /* WorkstreamApp */,);
			name = WorkstreamApp;
			productName = WorkstreamApp;
			productReference = 000000000000000000000120 /* WorkstreamApp.app */;
			productType = "com.apple.product-type.application";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		000000000000000000000000 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
				TargetAttributes = {000000000000000100000000 = {CreatedOnToolsVersion = 16.0; };};
			};
			buildConfigurationList = 000000000000000010000000;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (en, Base,);
			mainGroup = 000000000000000000000001;
			preferredProjectObjectVersion = 77;
			productRefGroup = 000000000000000000000020 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (000000000000000100000000 /* WorkstreamApp */,);
		};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		000000000000000140000000 /* Resources */ = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		000000000000000120000000 /* Sources */ = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		000000000000000011000000 /* Debug project */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CLANG_ENABLE_MODULES = YES;
				ENABLE_TESTABILITY = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			};
			name = Debug;
		};
		000000000000000012000000 /* Release project */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CLANG_ENABLE_MODULES = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				SWIFT_COMPILATION_MODE = wholemodule;
			};
			name = Release;
		};
		000000000000000111000000 /* Debug target */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = app.grokbuild.workstream.__BUNDLE_SUFFIX__;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = iphoneos;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			};
			name = Debug;
		};
		000000000000000112000000 /* Release target */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = app.grokbuild.workstream.__BUNDLE_SUFFIX__;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = iphoneos;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		000000000000000010000000 = {isa = XCConfigurationList; buildConfigurations = (000000000000000011000000, 000000000000000012000000,); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;};
		000000000000000110000000 = {isa = XCConfigurationList; buildConfigurations = (000000000000000111000000, 000000000000000112000000,); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;};
/* End XCConfigurationList section */
	};
	rootObject = 000000000000000000000000 /* Project object */;
}
'''
