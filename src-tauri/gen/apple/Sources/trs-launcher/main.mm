#import <BackgroundTasks/BackgroundTasks.h>
#import <Foundation/Foundation.h>
#include <sys/utsname.h>

#include "bindings/bindings.h"

// Hintergrundabruf der Push-Hinweise (Plugin trs-push, TrsPushPlugin.swift). iOS beendet die App, wenn ein
// BGTaskScheduler-Handler erst nach dem App-Start angemeldet wird – Tauri-Plugins laden aber erst mit der
// Web-Ansicht. Deshalb hier vor dem Start anmelden; die Arbeit macht weiter das Plugin.
@protocol TrsPushBackgroundTask
+ (void)handleBackgroundTask:(BGTask *)task;
@end

static void registerBackgroundTasks(void) {
	Class plugin = NSClassFromString(@"TrsPushPlugin");
	NSArray *identifiers = NSBundle.mainBundle.infoDictionary[@"BGTaskSchedulerPermittedIdentifiers"];
	if (!plugin || ![plugin respondsToSelector:@selector(handleBackgroundTask:)] || ![identifiers isKindOfClass:NSArray.class]) {
		return;
	}
	for (NSString *identifier in identifiers) {
		if (![identifier isKindOfClass:NSString.class] || ![identifier hasSuffix:@".push-poll"]) continue;
		[BGTaskScheduler.sharedScheduler registerForTaskWithIdentifier:identifier usingQueue:nil launchHandler:^(BGTask *task) {
			[(Class<TrsPushBackgroundTask>)plugin handleBackgroundTask:task];
		}];
	}
}

// Absturzberichte (Plugin trs-ios, CrashReporter.swift): so früh wie möglich – auch Abstürze beim App-Start
// (UIKit-Prüfungen, Watchdog) landen dann in Dokumente/Crash Reports.
@protocol TrsCrashReporting
+ (void)install;
@end

static void installCrashReporter(void) {
	Class reporter = NSClassFromString(@"TrsCrashReporter");
	if (reporter && [reporter respondsToSelector:@selector(install)]) {
		[(Class<TrsCrashReporting>)reporter install];
	}
}

// Modell und iOS-Version für die Kopfzeile der Rust-Berichte (crash_report.rs) – Rust kennt sie sonst nicht.
static void exportDeviceInfo(void) {
	struct utsname info;
	if (uname(&info) == 0) setenv("TRS_DEVICE_MODEL", info.machine, 1);
	NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
	NSString *version = v.patchVersion > 0
		? [NSString stringWithFormat:@"%ld.%ld.%ld", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion]
		: [NSString stringWithFormat:@"%ld.%ld", (long)v.majorVersion, (long)v.minorVersion];
	setenv("TRS_OS_VERSION", version.UTF8String, 1);
}

int main(int argc, char * argv[]) {
	@autoreleasepool {
		exportDeviceInfo();
		installCrashReporter();
		registerBackgroundTasks();
	}
	ffi::start_app();
	return 0;
}
