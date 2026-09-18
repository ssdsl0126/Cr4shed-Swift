#import "Cr4shedCommon.h"
#include <mach-o/dyld_images.h>
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
