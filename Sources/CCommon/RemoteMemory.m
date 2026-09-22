#import "Cr4shedCommon.h"
#include <mach-o/dyld_images.h>
#include <mach/mach_time.h>
#include <mach/vm_statistics.h>
#include <stdlib.h>
#include <string.h>

#define MAX_CHUNK_SIZE 0xFFF

extern kern_return_t mach_vm_read_overwrite(vm_map_t target_task, mach_vm_address_t address, mach_vm_size_t size, mach_vm_address_t data, mach_vm_size_t *outsize);
extern kern_return_t mach_vm_write(vm_map_t target_task, mach_vm_address_t address, vm_offset_t data, mach_msg_type_number_t dataCnt);

size_t CR4RRead(mach_port_t task, mach_vm_address_t where, void *p, size_t size) {
    size_t offset = 0;
    while (offset < size) {
        mach_vm_size_t sz = 0, chunk = MAX_CHUNK_SIZE;
        if (chunk > size - offset) chunk = size - offset;
        kern_return_t rv = mach_vm_read_overwrite(task, where + offset, chunk, (mach_vm_address_t)p + offset, &sz);
        if (rv || sz == 0) break;
        offset += sz;
    }
    return offset;
}

char *CR4RReadString(mach_port_t task, vm_address_t addr) {
    const size_t batchSz = 8;
    char *str = NULL;
    size_t sz = 0;
    for (;;) {
        char *nstr = (char *)realloc(str, sz + batchSz);
        if (!nstr) {
            free(str);
            return NULL;
        }
        str = nstr;
        char *cursor = &str[sz];
        CR4RRead(task, addr + sz, cursor, batchSz);
        if (strnlen(cursor, batchSz) != batchSz) break;
        sz += batchSz;
    }
    return str;
}

uint64_t CR4RRead64(mach_port_t task, mach_vm_address_t where) {
    uint64_t val = 0;
    CR4RRead(task, where, &val, sizeof(val));
    return val;
}

uint32_t CR4RRead32(mach_port_t task, mach_vm_address_t where) {
    uint32_t val = 0;
    CR4RRead(task, where, &val, sizeof(val));
    return val;
}

mach_vm_address_t CR4TaskGetImageInfos(mach_port_t task) {
    struct task_dyld_info dyld_info = {0};
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t kr = task_info(task, TASK_DYLD_INFO, (task_info_t)&dyld_info, &count);
    if (kr == KERN_SUCCESS && dyld_info.all_image_info_addr && dyld_info.all_image_info_size)
        return dyld_info.all_image_info_addr;
    return 0;
}

static NSString *CR4MemoryTagName(unsigned int tag) {
    switch (tag) {
        case VM_MEMORY_MALLOC: return @"MALLOC";
        case VM_MEMORY_MALLOC_SMALL: return @"MALLOC_SMALL";
        case VM_MEMORY_MALLOC_LARGE: return @"MALLOC_LARGE";
        case VM_MEMORY_MALLOC_HUGE: return @"MALLOC_HUGE";
        case VM_MEMORY_REALLOC: return @"MALLOC_REALLOC";
        case VM_MEMORY_MALLOC_TINY: return @"MALLOC_TINY";
        case VM_MEMORY_MALLOC_LARGE_REUSABLE: return @"MALLOC_LARGE_REUSABLE";
        case VM_MEMORY_MALLOC_LARGE_REUSED: return @"MALLOC_LARGE_REUSED";
        case VM_MEMORY_MALLOC_NANO: return @"MALLOC_NANO";
        case VM_MEMORY_MALLOC_MEDIUM: return @"MALLOC_MEDIUM";
        case VM_MEMORY_MALLOC_PROB_GUARD: return @"MALLOC_PROB_GUARD";
        case VM_MEMORY_MACH_MSG: return @"Mach message";
        case VM_MEMORY_IOKIT: return @"IOKit";
        case VM_MEMORY_OBJC_DISPATCHERS: return @"Objective-C dispatchers";
        case VM_MEMORY_FOUNDATION: return @"Foundation";
        case VM_MEMORY_CORESERVICES: return @"CoreServices";
        case VM_MEMORY_COREDATA:
        case VM_MEMORY_COREDATA_OBJECTIDS: return @"CoreData";
        case VM_MEMORY_IOSURFACE: return @"IOSurface";
        case VM_MEMORY_CGIMAGE: return @"CGImage";
        case VM_MEMORY_IMAGEIO: return @"ImageIO";
        case VM_MEMORY_COREGRAPHICS:
        case VM_MEMORY_COREGRAPHICS_DATA:
        case VM_MEMORY_COREGRAPHICS_SHARED:
        case VM_MEMORY_COREGRAPHICS_FRAMEBUFFERS:
        case VM_MEMORY_COREGRAPHICS_BACKINGSTORES:
        case VM_MEMORY_COREGRAPHICS_XALLOC: return @"CoreGraphics";
        case VM_MEMORY_COREIMAGE: return @"CoreImage";
        case VM_MEMORY_SWIFT_RUNTIME: return @"Swift runtime";
        case VM_MEMORY_SWIFT_METADATA: return @"Swift metadata";
        case VM_MEMORY_JAVASCRIPT_CORE: return @"JavaScriptCore";
        case VM_MEMORY_STACK: return @"Stack";
        case VM_MEMORY_DYLIB: return @"Dylib";
        case VM_MEMORY_DYLD: return @"Dyld";
        case VM_MEMORY_DYLD_MALLOC: return @"Dyld malloc";
        case VM_MEMORY_SQLITE: return @"SQLite";
        case VM_MEMORY_OS_ALLOC_ONCE: return @"os_alloc_once";
        case VM_MEMORY_LIBDISPATCH: return @"libdispatch";
        case VM_MEMORY_GENEALOGY: return @"Genealogy";
        case VM_MEMORY_ASL: return @"System logging";
        default: return @"Other/untagged";
    }
}

static bool CR4IsMallocTag(unsigned int tag) {
    switch (tag) {
        case VM_MEMORY_MALLOC:
        case VM_MEMORY_MALLOC_SMALL:
        case VM_MEMORY_MALLOC_LARGE:
        case VM_MEMORY_MALLOC_HUGE:
        case VM_MEMORY_REALLOC:
        case VM_MEMORY_MALLOC_TINY:
        case VM_MEMORY_MALLOC_LARGE_REUSABLE:
        case VM_MEMORY_MALLOC_LARGE_REUSED:
        case VM_MEMORY_MALLOC_NANO:
        case VM_MEMORY_MALLOC_MEDIUM:
        case VM_MEMORY_MALLOC_PROB_GUARD:
            return true;
        default:
            return false;
    }
}

static NSString *CR4TaskMemoryRegions(mach_port_t task, uint64_t pageSize, uint64_t expectedPrivateLedger) {
    struct {
        uint64_t privateResident;
        uint64_t swapped;
        uint64_t dirty;
        unsigned int regions;
    } buckets[257] = {0};
    struct {
        uint64_t total;
        uint64_t privateResident;
        uint64_t swapped;
        vm_address_t address;
        vm_size_t virtualSize;
        unsigned int tag;
    } largestRegions[8] = {0};
    vm_address_t address = 0;
    natural_t depth = 0;
    unsigned int scannedRegions = 0;
    unsigned int rankedRegions = 0;
    unsigned int skippedSubmaps = 0;
    unsigned int excludedMappings = 0;
    uint64_t rankedPrivateResident = 0;
    uint64_t rankedPrivateSwapped = 0;
    uint64_t mallocPrivateResident = 0;
    uint64_t mallocPrivateSwapped = 0;
    unsigned int queryCount = 0;
    NSString *status = @"partial: region query limit";
    mach_timebase_info_data_t timebase = {0};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.numer || !timebase.denom) {
        return @"VM region summary: unavailable (clock)\n";
    }
    const uint64_t started = mach_absolute_time();
    const uint64_t budget = 500ull * NSEC_PER_MSEC * timebase.denom / timebase.numer;
    // 只在资源异常的报告进程采集。较高地址的 malloc 区通常位于大量镜像映射之后，
    // 因此允许最多 500 ms；仍不读取目标堆内容或安装 malloc hook。
    for (unsigned int query = 0; query < 4096; query++) {
        if (mach_absolute_time() - started >= budget) {
            status = @"partial: time budget";
            break;
        }
        queryCount++;
        vm_size_t size = 0;
        vm_region_submap_info_data_64_t region = {0};
        // v0 已包含所需计数，避免向旧系统要求新版本尾部字段。
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_V0_COUNT_64;
        kern_return_t result = vm_region_recurse_64(task, &address, &size, &depth,
                                                   (vm_region_recurse_info_t)&region, &count);
        if (result != KERN_SUCCESS) {
            status = result == KERN_INVALID_ADDRESS ? @"complete" : [NSString stringWithFormat:@"partial: kern_return %d", result];
            break;
        }
        if (count < VM_REGION_SUBMAP_INFO_V0_COUNT_64 || size == 0) {
            status = @"partial: invalid region metadata";
            break;
        }
        if (region.is_submap) {
            // 私有子映射继续递归；共享或别名子映射通常是 dyld shared cache，
            // 逐项展开会重复计算共享页并耗尽时间预算。
            if (region.share_mode == SM_PRIVATE) {
                if (depth >= 32) {
                    status = @"partial: nesting limit";
                    break;
                }
                depth++;
                continue;
            }
            skippedSubmaps++;
            if (address > UINTPTR_MAX - size) {
                status = @"partial: address overflow";
                break;
            }
            address += size;
            continue;
        }

        scannedRegions++;
        uint64_t privateResidentPages = 0;
        uint64_t privateSwappedPages = 0;
        switch (region.share_mode) {
            case SM_PRIVATE:
                // 外部分页器表示文件后备；只把已经 COW 成私有的页列入诊断估算。
                privateResidentPages = region.external_pager
                    ? MIN(region.pages_resident, region.pages_shared_now_private)
                    : region.pages_resident;
                privateSwappedPages = region.pages_swapped_out;
                break;
            case SM_COW:
                privateResidentPages = MIN(region.pages_resident, region.pages_shared_now_private);
                privateSwappedPages = region.pages_swapped_out;
                break;
            default:
                // 共享、true-shared 及 aliased 映射不参与独占成本排名。
                excludedMappings++;
                break;
        }

        if (privateResidentPages || privateSwappedPages) {
            const uint64_t privatePages = privateResidentPages + privateSwappedPages;
            const uint64_t dirtyPages = MIN((uint64_t)region.pages_dirtied, privatePages);
            unsigned int tag = MIN(region.user_tag, 256u);
            buckets[tag].regions++;
            buckets[tag].privateResident += privateResidentPages * pageSize;
            buckets[tag].swapped += privateSwappedPages * pageSize;
            buckets[tag].dirty += dirtyPages * pageSize;
            rankedPrivateResident += privateResidentPages * pageSize;
            rankedPrivateSwapped += privateSwappedPages * pageSize;
            if (CR4IsMallocTag(tag)) {
                mallocPrivateResident += privateResidentPages * pageSize;
                mallocPrivateSwapped += privateSwappedPages * pageSize;
            }
            rankedRegions++;

            const uint64_t total = (privateResidentPages + privateSwappedPages) * pageSize;
            for (unsigned int index = 0; index < 8; index++) {
                if (total <= largestRegions[index].total) continue;
                for (unsigned int move = 7; move > index; move--) {
                    largestRegions[move] = largestRegions[move - 1];
                }
                largestRegions[index].total = total;
                largestRegions[index].privateResident = privateResidentPages * pageSize;
                largestRegions[index].swapped = privateSwappedPages * pageSize;
                largestRegions[index].address = address;
                largestRegions[index].virtualSize = size;
                largestRegions[index].tag = tag;
                break;
            }
        }
        if (address > UINTPTR_MAX - size) {
            status = @"partial: address overflow";
            break;
        }
        address += size;
    }
    const double elapsedMilliseconds = (double)(mach_absolute_time() - started)
        * (double)timebase.numer / (double)timebase.denom / (double)NSEC_PER_MSEC;
    const double rankedTotal = (double)(rankedPrivateResident + rankedPrivateSwapped);
    const double coverage = expectedPrivateLedger ? rankedTotal * 100.0 / (double)expectedPrivateLedger : 0.0;
    const double mallocTotal = (double)(mallocPrivateResident + mallocPrivateSwapped);
    const double mallocShare = rankedTotal ? mallocTotal * 100.0 / rankedTotal : 0.0;
    NSMutableString *text = [NSMutableString stringWithFormat:
        @"VM private-region summary: %@; %u queries in %.1f ms; scanned %u regions, ranked %u, skipped %u shared/aliased submaps, excluded %u shared/aliased mappings; page size %llu bytes\n"
         "Ranked private estimate: resident %.2f MiB, swapped %.2f MiB, coverage %.1f%% of internal + compressed ledger (clean file-backed pages omitted)\n"
         "MALLOC aggregate: private resident %.2f MiB, swapped %.2f MiB, %.1f%% of ranked private estimate\n"
         "Top VM tags by estimated private resident + swapped pages (MiB; diagnostic estimate, not a footprint sum):\n",
        status, queryCount, elapsedMilliseconds, scannedRegions, rankedRegions,
        skippedSubmaps, excludedMappings, (unsigned long long)pageSize,
        rankedPrivateResident / 1048576.0, rankedPrivateSwapped / 1048576.0, coverage,
        mallocPrivateResident / 1048576.0, mallocPrivateSwapped / 1048576.0, mallocShare];
    unsigned int emitted = 0;
    for (unsigned int row = 0; row < 12; row++) {
        unsigned int best = 0;
        for (unsigned int tag = 1; tag < 257; tag++) {
            if (buckets[tag].privateResident + buckets[tag].swapped >
                buckets[best].privateResident + buckets[best].swapped) best = tag;
        }
        if (buckets[best].privateResident + buckets[best].swapped == 0) break;
        [text appendFormat:@"  %@ (tag %u): private resident %.2f, swapped %.2f, dirty/private %.2f, regions %u\n",
            CR4MemoryTagName(best), best, buckets[best].privateResident / 1048576.0,
            buckets[best].swapped / 1048576.0, buckets[best].dirty / 1048576.0, buckets[best].regions];
        buckets[best].privateResident = buckets[best].swapped = 0;
        emitted++;
    }
    if (!emitted) [text appendString:@"  No private resident or swapped regions captured\n"];
    [text appendString:@"Largest private VM regions by resident + swapped pages:\n"];
    unsigned int regionRows = 0;
    for (unsigned int index = 0; index < 8; index++) {
        if (!largestRegions[index].total) break;
        [text appendFormat:@"  0x%llx: %@ (tag %u), private resident %.2f MiB, swapped %.2f MiB, virtual %.2f MiB\n",
            (unsigned long long)largestRegions[index].address,
            CR4MemoryTagName(largestRegions[index].tag), largestRegions[index].tag,
            largestRegions[index].privateResident / 1048576.0,
            largestRegions[index].swapped / 1048576.0,
            (double)largestRegions[index].virtualSize / 1048576.0];
        regionRows++;
    }
    if (!regionRows) [text appendString:@"  No private regions captured\n"];
    return text;
}

NSString *CR4TaskMemoryDescription(mach_port_t task) {
    if (!MACH_PORT_VALID(task)) return nil;
    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t result = task_info(task, TASK_VM_INFO, (task_info_t)&info, &count);
    // 旧系统可能只返回部分字段；失败时不把未知占用写成零。
    if (result != KERN_SUCCESS || count < TASK_VM_INFO_REV1_COUNT) {
        return [NSString stringWithFormat:@"Memory snapshot: unavailable (kern_return %d, info count %u)\n", result, count];
    }
    // 这是报告采集时的快照，不能当作触发异常瞬间的峰值。
    NSMutableString *text = [NSMutableString stringWithFormat:
        @"Memory footprint at capture: %llu bytes (%.2f MiB)\nResident memory at capture: %llu bytes (%.2f MiB)\n"
         "Internal memory: %.2f MiB\nCompressed memory: %.2f MiB\nDevice memory: %.2f MiB\n",
        (unsigned long long)info.phys_footprint, (double)info.phys_footprint / (1024.0 * 1024.0),
        (unsigned long long)info.resident_size, (double)info.resident_size / (1024.0 * 1024.0),
        info.internal / 1048576.0, info.compressed / 1048576.0, info.device / 1048576.0];
    if (count >= TASK_VM_INFO_REV3_COUNT) {
        [text appendFormat:@"Lifetime footprint peak: %.2f MiB\nGraphics ledger: %.2f MiB (compressed %.2f)\nMedia ledger: %.2f MiB (compressed %.2f)\n",
            info.ledger_phys_footprint_peak / 1048576.0,
            info.ledger_tag_graphics_footprint / 1048576.0, info.ledger_tag_graphics_footprint_compressed / 1048576.0,
            info.ledger_tag_media_footprint / 1048576.0, info.ledger_tag_media_footprint_compressed / 1048576.0];
    }
    if (count >= TASK_VM_INFO_REV4_COUNT) {
        [text appendFormat:@"Memory limit remaining at capture: %.2f MiB\n", info.limit_bytes_remaining / 1048576.0];
    }
    uint64_t pageSize = info.page_size > 0 ? (uint64_t)info.page_size : (uint64_t)vm_page_size;
    if (pageSize) [text appendString:CR4TaskMemoryRegions(task, pageSize, info.internal + info.compressed)];
    return text;
}

void CR4MarkProcessAsHandled(void) {
    struct dyld_all_image_infos *image_infos = (struct dyld_all_image_infos *)CR4TaskGetImageInfos(mach_task_self());
    if (image_infos) image_infos->errorMessage = CR4SHED_HANDLED_FLAG;
}

bool CR4ProcessHasBeenHandled(mach_port_t task) {
    bool handled = false;
    mach_vm_address_t image_infos = CR4TaskGetImageInfos(task);
    if (!image_infos) return false;
    uint64_t errorMsgAddr = 0;
    CR4RRead(task, image_infos + offsetof(struct dyld_all_image_infos, errorMessage), &errorMsgAddr, sizeof(uint64_t));
    if (!errorMsgAddr) return false;
    size_t flagLen = strlen(CR4SHED_HANDLED_FLAG) + 1;
    void *mem = malloc(flagLen);
    if (!mem) return false;
    CR4RRead(task, errorMsgAddr, mem, flagLen);
    handled = (memcmp(mem, CR4SHED_HANDLED_FLAG, flagLen - 1) == 0);
    free(mem);
    return handled;
}
