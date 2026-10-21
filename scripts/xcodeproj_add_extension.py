#!/usr/bin/env python3
"""Adds an app-extension target to App/Xipper.xcodeproj (synchronized folder App/<Name>),
embedded in Xipper.app/Contents/PlugIns, optionally linking XipperKit.

usage: scripts/xcodeproj_add_extension.py <Name> <bundle-id> [--kit] [--display "Name"]
The folder App/<Name> must contain Info.plist and <Name>.entitlements."""
import hashlib, sys

def oid(name): return hashlib.md5(name.encode()).hexdigest()[:24].upper()

name, bundle = sys.argv[1], sys.argv[2]
kit = '--kit' in sys.argv
display = sys.argv[sys.argv.index('--display') + 1] if '--display' in sys.argv else name
p = 'App/Xipper.xcodeproj/project.pbxproj'
s = open(p).read()
if f'/* {name} */ = {{\n\t\t\tisa = PBXNativeTarget;' in s:
    sys.exit(f'{name} already present')
T = {k: oid(f'{name}-{k}') for k in ['target', 'product', 'group', 'exceptions', 'sources', 'frameworks', 'resources',
                                      'cfglist', 'debug', 'release', 'proxy', 'tdep', 'copyfile', 'kitfile', 'kitdep']}
EMBED = oid('fx-copyphase')  # "Embed Extensions" phase created with the Finder extension
PROJECT, PKGREF = oid('project'), oid('pkgref')

def ins(section, text):
    global s
    marker = f'/* End {section} section */'
    assert marker in s, section
    s = s.replace(marker, text + marker, 1)

def after(anchor, text):
    global s
    assert anchor in s, anchor[:60]
    s = s.replace(anchor, anchor + text, 1)

ins('PBXBuildFile', f'\t\t{T["copyfile"]} /* {name}.appex in Embed Extensions */ = {{isa = PBXBuildFile; fileRef = {T["product"]} /* {name}.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};\n'
    + (f'\t\t{T["kitfile"]} /* XipperKit in Frameworks */ = {{isa = PBXBuildFile; productRef = {T["kitdep"]} /* XipperKit */; }};\n' if kit else ''))
ins('PBXContainerItemProxy', f'''		{T["proxy"]} /* PBXContainerItemProxy */ = {{
			isa = PBXContainerItemProxy;
			containerPortal = {PROJECT} /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = {T["target"]};
			remoteInfo = {name};
		}};
''')
after(f'{EMBED} /* Embed Extensions */ = {{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tdstPath = "";\n\t\t\tdstSubfolderSpec = 13;\n\t\t\tfiles = (\n',
      f'\t\t\t\t{T["copyfile"]} /* {name}.appex in Embed Extensions */,\n')
ins('PBXFileReference', f'\t\t{T["product"]} /* {name}.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = {name}.appex; sourceTree = BUILT_PRODUCTS_DIR; }};\n')
ins('PBXFileSystemSynchronizedBuildFileExceptionSet', f'''		{T["exceptions"]} /* Exceptions for "{name}" folder in "{name}" target */ = {{
			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
			membershipExceptions = (
				Info.plist,
				{name}.entitlements,
			);
			target = {T["target"]} /* {name} */;
		}};
''')
ins('PBXFileSystemSynchronizedRootGroup', f'''		{T["group"]} /* {name} */ = {{
			isa = PBXFileSystemSynchronizedRootGroup;
			exceptions = (
				{T["exceptions"]} /* Exceptions for "{name}" folder in "{name}" target */,
			);
			path = {name};
			sourceTree = "<group>";
		}};
''')
ins('PBXFrameworksBuildPhase', f'''		{T["frameworks"]} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
{f"				{T['kitfile']} /* XipperKit in Frameworks */,{chr(10)}" if kit else ""}			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
''')
after(f'\t\t\t\t{oid("appgroup")} /* Xipper */,\n', f'\t\t\t\t{T["group"]} /* {name} */,\n')
after(f'\t\t\t\t{oid("app")} /* Xipper.app */,\n', f'\t\t\t\t{T["product"]} /* {name}.appex */,\n')
after(f'\t\t\t\t{oid("fx-tdep")} /* PBXTargetDependency */,\n', f'\t\t\t\t{T["tdep"]} /* PBXTargetDependency */,\n')
ins('PBXNativeTarget', f'''		{T["target"]} /* {name} */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {T["cfglist"]} /* Build configuration list for PBXNativeTarget "{name}" */;
			buildPhases = (
				{T["sources"]} /* Sources */,
				{T["frameworks"]} /* Frameworks */,
				{T["resources"]} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				{T["group"]} /* {name} */,
			);
			name = {name};
{f"			packageProductDependencies = ({chr(10)}				{T['kitdep']} /* XipperKit */,{chr(10)}			);{chr(10)}" if kit else ""}			productName = {name};
			productReference = {T["product"]} /* {name}.appex */;
			productType = "com.apple.product-type.app-extension";
		}};
''')
after(f'\t\t\t\t{oid("fx-target")} /* XipperFinder */,\n', f'\t\t\t\t{T["target"]} /* {name} */,\n')
for sec, key in [('PBXResourcesBuildPhase', 'resources'), ('PBXSourcesBuildPhase', 'sources')]:
    isa = sec
    ins(sec, f'''		{T[key]} /* {"Resources" if key == "resources" else "Sources"} */ = {{
			isa = {isa};
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
''')
ins('PBXTargetDependency', f'''		{T["tdep"]} /* PBXTargetDependency */ = {{
			isa = PBXTargetDependency;
			target = {T["target"]} /* {name} */;
			targetProxy = {T["proxy"]} /* PBXContainerItemProxy */;
		}};
''')
settings = f'''				CODE_SIGN_ENTITLEMENTS = {name}/{name}.entitlements;
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Manual;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_APP_SANDBOX = YES;
				ENABLE_HARDENED_RUNTIME = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = {name}/Info.plist;
				INFOPLIST_KEY_CFBundleDisplayName = "{display}";
				LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks";
				MARKETING_VERSION = 0.9.0;
				PRODUCT_BUNDLE_IDENTIFIER = {bundle};
				PRODUCT_NAME = {name};
				SKIP_INSTALL = YES;
				SWIFT_STRICT_CONCURRENCY = complete;'''
ins('XCBuildConfiguration', f'''		{T["debug"]} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{settings}
			}};
			name = Debug;
		}};
		{T["release"]} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{settings}
			}};
			name = Release;
		}};
''')
ins('XCConfigurationList', f'''		{T["cfglist"]} /* Build configuration list for PBXNativeTarget "{name}" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{T["debug"]} /* Debug */,
				{T["release"]} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
''')
if kit:
    ins('XCSwiftPackageProductDependency', f'''		{T["kitdep"]} /* XipperKit */ = {{
			isa = XCSwiftPackageProductDependency;
			package = {PKGREF} /* XCLocalSwiftPackageReference ".." */;
			productName = XipperKit;
		}};
''')
open(p, 'w').write(s)
print(f'added {name} ({bundle})')
