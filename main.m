#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/sysctl.h>
#import <Foundation/Foundation.h>

#if TARGET_OS_IPHONE
// iOS code
#else
// OSX code
#endif

static NSArray *AllProcesses(void)
{
	int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
	size_t miblen = 4;
	size_t size;
	int st = sysctl(mib, miblen, NULL, &size, NULL, 0);
	struct kinfo_proc *process = NULL;
	struct kinfo_proc *newprocess = NULL;
	do
	{
		size += size / 10;
		newprocess = realloc(process, size);
		if (!newprocess)
		{
			if (process)
			{
				free(process);
			}
			return nil;
		}
		process = newprocess;
		st = sysctl(mib, miblen, process, &size, NULL, 0);
	}
	while (st == -1 && errno == ENOMEM);
	if (st == 0)
	{
		if (size % sizeof(struct kinfo_proc) == 0)
		{
			int nprocess = size / sizeof(struct kinfo_proc);
			if (nprocess)
			{
				NSMutableArray * array = [[NSMutableArray alloc] init];
				for (int i = nprocess - 1; i >= 0; i--)
				{
					NSString * processID = [[NSString alloc] initWithFormat:@"%d", process[i].kp_proc.p_pid];
					NSString * processName = [[NSString alloc] initWithFormat:@"%s", process[i].kp_proc.p_comm];
					NSDictionary * dictionary = [[NSDictionary alloc] initWithObjects:[NSArray arrayWithObjects:processID, processName, nil] forKeys:[NSArray arrayWithObjects:@"ProcessID", @"ProcessName", nil]];
					[processID release];
					[processName release];
					[array addObject:dictionary];
					[dictionary release];
				}
				free(process);
				return [array autorelease];
			}
		}
	}
	return nil;
}

int main(int argc, char *argv[])
{
	// Output all Process IDs and names
	printf("[PID] ProcessName\n");
	for (NSDictionary *process in AllProcesses())
	{
		printf("[%s] %s\n", [(NSString *)[process objectForKey:@"ProcessID"] UTF8String], [(NSString *)[process objectForKey:@"ProcessName"] UTF8String]);
	}

	// Prompt
	printf("Enter target PID: ");
	int pid = 0;
	scanf("%d", &pid);

	// Get task of specified PID
	kern_return_t kret;
	mach_port_t task;
	if ((kret = task_for_pid(mach_task_self(), pid, &task)) != KERN_SUCCESS)
	{
		printf("task_for_pid() failed, error %d: %s. Forgot to run as root?\n", kret, mach_error_string(kret));
		exit(1);
	}

	NSMutableArray *substringArray = [[NSMutableArray alloc] initWithCapacity:666];
	NSMutableArray *protectionArray = [[NSMutableArray alloc] initWithCapacity:666];
Search:
	// Prompt
	printf("Enter the value to search: ");
	int targetValue = 0;
	scanf("%d", &targetValue);

	// Output all searched results
	mach_vm_address_t address = 0;
	mach_vm_size_t size;
	mach_port_t object_name;
	vm_region_basic_info_data_t info;
	mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
	int occurranceCount = 0;
	[substringArray removeAllObjects];
	[protectionArray removeAllObjects];
	while (mach_vm_region(task, &address, &size, VM_REGION_BASIC_INFO, (vm_region_info_t)&info, &count, &object_name) == KERN_SUCCESS)
	{
		vm_offset_t buffer;
		mach_msg_type_number_t bufferSize = size;
		vm_prot_t protection = info.protection;
		if (mach_vm_read(task, address, size, &buffer, &bufferSize) == KERN_SUCCESS)
		{
			void *substring = NULL;
			if ((substring = memmem((const void *)buffer, bufferSize, &targetValue, sizeof(targetValue))) != NULL)
			{
				occurranceCount++;
				long realAddress = (long)substring - (long)buffer + (long)address;
				printf("Search result %2d: %d at 0x%0lx (%s)\n", occurranceCount, targetValue, realAddress, (protection & VM_PROT_WRITE) != 0 ? "writable" : "non-writable");
				[substringArray addObject:[NSNumber numberWithLong:realAddress]];
				[protectionArray addObject:[NSString stringWithUTF8String:(protection & VM_PROT_WRITE) != 0 ? "writable" : "non-writable"]];
			}
		}
		address += size;
	}
NextAction:
	// Prompt
	printf("1. Modify searched results;\n2. Review searched results;\n3. Search something else.\nPlease choose your next action: ");
	int nextAction;
	scanf("%d", &nextAction);

	// Modify searched results or review them
	switch (nextAction)
	{
		case 1:
			{
				// Prompt
				while (getchar() != '\n') continue; // clear buffer
				printf("Enter the address of modification: ");
				mach_vm_address_t modAddress;
				scanf("0x%llx", &modAddress);

				while (getchar() != '\n') continue; // clear buffer
				printf("Enter the new value: ");
				int newValue;
				scanf("%d", &newValue);

				if ((kret = mach_vm_write(task, modAddress, (vm_offset_t)&newValue, sizeof(newValue))) != KERN_SUCCESS) printf("mach_vm_write failed, error %d: %s\n", kret, mach_error_string(kret));
				goto NextAction;					
			}
		case 2:
			{
				for (int i = 0; i < [substringArray count]; i++)
				{
					NSNumber *substringNumber = [substringArray objectAtIndex:i];
					long substring = [substringNumber longValue];
					vm_offset_t buffer;
					mach_msg_type_number_t bufferSize = sizeof(int);
					if (mach_vm_read(task, substring, size, &buffer, &bufferSize) == KERN_SUCCESS)
					{
						printf("Search result %2d: %d at 0x%0lx (%s)\n", i + 1, *(int *)buffer, substring, [[protectionArray objectAtIndex:i] UTF8String]);
					}
				}
				goto NextAction;
			}
		case 3:
			{
				goto Search;
			}
		default:
			{
				printf("Unknown action. Please re-enter.\n");
				goto NextAction;
			}
	}
	[substringArray release];
	[protectionArray release];
	return 0;
}
