#import <BackgroundTasks/BackgroundTasks.h>
#import <Foundation/Foundation.h>

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

int main(int argc, char * argv[]) {
	@autoreleasepool {
		registerBackgroundTasks();
	}
	ffi::start_app();
	return 0;
}
