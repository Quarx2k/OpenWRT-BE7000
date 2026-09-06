/*
* kexec.c - kexec system call core code.
* Copyright (C) 2002-2004 Eric Biederman  <ebiederm@xmission.com>
*
* This source code is licensed under the GNU General Public License,
* Version 2.  See the file COPYING for more details.
*/

#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/capability.h>
#include <linux/mm.h>
#include <linux/file.h>
#include <linux/slab.h>
#include <linux/fs.h>
#include <linux/mutex.h>
#include <linux/list.h>
#include <linux/highmem.h>
#include <linux/syscalls.h>
#include <linux/reboot.h>
#include <linux/ioport.h>
#include <linux/hardirq.h>
#include <linux/elf.h>
#include <linux/elfcore.h>
#include <linux/utsname.h>
#include <linux/numa.h>
#include <linux/suspend.h>
#include <linux/device.h>
#include <linux/platform_device.h>
#include <linux/freezer.h>
#include <linux/pm.h>
#include <linux/cpu.h>
#include <linux/uaccess.h>
#include <linux/io.h>
#include <linux/console.h>
#include <linux/vmalloc.h>
#include <linux/swap.h>
#include <linux/syscore_ops.h>
#include <linux/compiler.h>
#include <linux/hugetlb.h>
#include <linux/frame.h>
#include <linux/delay.h>
#include <linux/idr.h>
#include <linux/interrupt.h>
#include <linux/kref.h>
#include <linux/mailbox_client.h>
#include <linux/workqueue.h>

#include <asm/page.h>
#include <asm/sections.h>

#include <crypto/hash.h>
#include <crypto/sha.h>

#include "kexec.h"
#include "kexec_breadcrumb.h"
#include "kexec_compat.h"
#include "kexec_internal.h"

DEFINE_MUTEX(kexec_mutex);

/* Flag to indicate we are going to kexec a new kernel */
bool kexec_in_progress = false;

/*
 * When kexec transitions to the new kernel there is a one-to-one
 * mapping between physical and virtual addresses.  On processors
 * where you can disable the MMU this is trivial, and easy.  For
 * others it is still a simple predictable page table to setup.
 *
 * In that environment kexec copies the new kernel to its final
 * resting place.  This means I can only support memory whose
 * physical address can fit in an unsigned long.  In particular
 * addresses where (pfn << PAGE_SHIFT) > ULONG_MAX cannot be handled.
 * If the assembly stub has more restrictive requirements
 * KEXEC_SOURCE_MEMORY_LIMIT and KEXEC_DEST_MEMORY_LIMIT can be
 * defined more restrictively in <asm/kexec.h>.
 *
 * The code for the transition from the current kernel to the
 * the new kernel is placed in the control_code_buffer, whose size
 * is given by KEXEC_CONTROL_PAGE_SIZE.  In the best case only a single
 * page of memory is necessary, but some architectures require more.
 * Because this memory must be identity mapped in the transition from
 * virtual to physical addresses it must live in the range
 * 0 - TASK_SIZE, as only the user space mappings are arbitrarily
 * modifiable.
 *
 * The assembly stub in the control code buffer is passed a linked list
 * of descriptor pages detailing the source pages of the new kernel,
 * and the destination addresses of those source pages.  As this data
 * structure is not used in the context of the current OS, it must
 * be self-contained.
 *
 * The code has been made to work with highmem pages and will use a
 * destination page in its final resting place (if it happens
 * to allocate it).  The end product of this is that most of the
 * physical address space, and most of RAM can be used.
 *
 * Future directions include:
 *  - allocating a page table with the control code buffer identity
 *    mapped, to simplify machine_kexec and make kexec_on_panic more
 *    reliable.
 */

/*
 * KIMAGE_NO_DEST is an impossible destination address..., for
 * allocating pages whose destination address we do not care about.
 */
#define KIMAGE_NO_DEST (-1UL)
#define PAGE_COUNT(x) (((x) + PAGE_SIZE - 1) >> PAGE_SHIFT)

static struct page *kimage_alloc_page(struct kimage *image,
				     gfp_t gfp_mask,
				     unsigned long dest);

int sanity_check_segment_list(struct kimage *image)
{
       int i;
       unsigned long nr_segments = image->nr_segments;
       unsigned long total_pages = 0;

       /*
	* Verify we have good destination addresses.  The caller is
	* responsible for making certain we don't attempt to load
	* the new image into invalid or reserved areas of RAM.  This
	* just verifies it is an address we can use.
	*
	* Since the kernel does everything in page size chunks ensure
	* the destination addresses are page aligned.  Too many
	* special cases crop of when we don't do this.  The most
	* insidious is getting overlapping destination addresses
	* simply because addresses are changed to page size
	* granularity.
	*/
       for (i = 0; i < nr_segments; i++) {
	       unsigned long mstart, mend;

	       mstart = image->segment[i].mem;
	       mend   = mstart + image->segment[i].memsz;
	       if (mstart > mend)
		       return -EADDRNOTAVAIL;
	       if ((mstart & ~PAGE_MASK) || (mend & ~PAGE_MASK))
		       return -EADDRNOTAVAIL;
	       if (mend >= KEXEC_DESTINATION_MEMORY_LIMIT)
		       return -EADDRNOTAVAIL;
       }

       /* Verify our destination addresses do not overlap.
	* If we alloed overlapping destination addresses
	* through very weird things can happen with no
	* easy explanation as one segment stops on another.
	*/
       for (i = 0; i < nr_segments; i++) {
	       unsigned long mstart, mend;
	       unsigned long j;

	       mstart = image->segment[i].mem;
	       mend   = mstart + image->segment[i].memsz;
	       for (j = 0; j < i; j++) {
		       unsigned long pstart, pend;

		       pstart = image->segment[j].mem;
		       pend   = pstart + image->segment[j].memsz;
		       /* Do the segments overlap ? */
		       if ((mend > pstart) && (mstart < pend))
			       return -EINVAL;
	       }
       }

       /* Ensure our buffer sizes are strictly less than
	* our memory sizes.  This should always be the case,
	* and it is easier to check up front than to be surprised
	* later on.
	*/
       for (i = 0; i < nr_segments; i++) {
	       if (image->segment[i].bufsz > image->segment[i].memsz)
		       return -EINVAL;
       }

       /*
	* Verify that no more than half of memory will be consumed. If the
	* request from userspace is too large, a large amount of time will be
	* wasted allocating pages, which can cause a soft lockup.
	*/
       for (i = 0; i < nr_segments; i++) {
	       if (PAGE_COUNT(image->segment[i].memsz) > totalram_pages() / 2)
		       return -EINVAL;

	       total_pages += PAGE_COUNT(image->segment[i].memsz);
       }

       if (total_pages > totalram_pages() / 2)
	       return -EINVAL;

       return 0;
}

struct kimage *do_kimage_alloc_init(void)
{
       struct kimage *image;

       /* Allocate a controlling structure */
       image = kzalloc(sizeof(*image), GFP_KERNEL);
       if (!image)
	       return NULL;

       image->head = 0;
       image->entry = &image->head;
       image->last_entry = &image->head;
       image->control_page = ~0; /* By default this does not apply */

       /* Initialize the list of control pages */
       INIT_LIST_HEAD(&image->control_pages);

       /* Initialize the list of destination pages */
       INIT_LIST_HEAD(&image->dest_pages);

       /* Initialize the list of unusable pages */
       INIT_LIST_HEAD(&image->unusable_pages);

       return image;
}

int kimage_is_destination_range(struct kimage *image,
			       unsigned long start,
			       unsigned long end)
{
       unsigned long i;

       for (i = 0; i < image->nr_segments; i++) {
	       unsigned long mstart, mend;

	       mstart = image->segment[i].mem;
	       mend = mstart + image->segment[i].memsz;
	       if ((end > mstart) && (start < mend))
		       return 1;
       }

       return 0;
}

static struct page *kimage_alloc_pages(gfp_t gfp_mask, unsigned int order)
{
       struct page *pages;

       pages = alloc_pages(gfp_mask & ~__GFP_ZERO, order);
       if (pages) {
	       unsigned int count, i;

	       pages->mapping = NULL;
	       set_page_private(pages, order);
	       count = 1 << order;
	       for (i = 0; i < count; i++)
		       SetPageReserved(pages + i);

	       arch_kexec_post_alloc_pages(page_address(pages), count,
					   gfp_mask);

	       if (gfp_mask & __GFP_ZERO)
		       for (i = 0; i < count; i++)
			       clear_highpage(pages + i);
       }

       return pages;
}

static void kimage_free_pages(struct page *page)
{
       unsigned int order, count, i;

       order = page_private(page);
       count = 1 << order;

       arch_kexec_pre_free_pages(page_address(page), count);

       for (i = 0; i < count; i++)
	       ClearPageReserved(page + i);
       __free_pages(page, order);
}

void kimage_free_page_list(struct list_head *list)
{
       struct page *page, *next;

       list_for_each_entry_safe(page, next, list, lru) {
	       list_del(&page->lru);
	       kimage_free_pages(page);
       }
}

struct page *kimage_alloc_control_pages(struct kimage *image,
					unsigned int order)
{
       /* Control pages are special, they are the intermediaries
	* that are needed while we copy the rest of the pages
	* to their final resting place.  As such they must
	* not conflict with either the destination addresses
	* or memory the kernel is already using.
	*
	* The only case where we really need more than one of
	* these are for architectures where we cannot disable
	* the MMU and must instead generate an identity mapped
	* page table for all of the memory.
	*
	* At worst this runs in O(N) of the image size.
	*/
       struct list_head extra_pages;
       struct page *pages;
       unsigned int count;

       count = 1 << order;
       INIT_LIST_HEAD(&extra_pages);

       /* Loop while I can allocate a page and the page allocated
	* is a destination page.
	*/
       do {
	       unsigned long pfn, epfn, addr, eaddr;

	       pages = kimage_alloc_pages(KEXEC_CONTROL_MEMORY_GFP, order);
	       if (!pages)
		       break;
	       pfn   = page_to_boot_pfn(pages);
	       epfn  = pfn + count;
	       addr  = pfn << PAGE_SHIFT;
	       eaddr = epfn << PAGE_SHIFT;
	       if ((epfn >= (KEXEC_CONTROL_MEMORY_LIMIT >> PAGE_SHIFT)) ||
		   kimage_is_destination_range(image, addr, eaddr)) {
		       list_add(&pages->lru, &extra_pages);
		       pages = NULL;
	       }
       } while (!pages);

       if (pages) {
	       /* Remember the allocated page... */
	       list_add(&pages->lru, &image->control_pages);

	       /* Because the page is already in it's destination
		* location we will never allocate another page at
		* that address.  Therefore kimage_alloc_pages
		* will not return it (again) and we don't need
		* to give it an entry in image->segment[].
		*/
       }
       /* Deal with the destination pages I have inadvertently allocated.
	*
	* Ideally I would convert multi-page allocations into single
	* page allocations, and add everything to image->dest_pages.
	*
	* For now it is simpler to just free the pages.
	*/
       kimage_free_page_list(&extra_pages);

       return pages;
}

static int kimage_add_entry(struct kimage *image, kimage_entry_t entry)
{
       if (*image->entry != 0)
	       image->entry++;

       if (image->entry == image->last_entry) {
	       kimage_entry_t *ind_page;
	       struct page *page;

	       page = kimage_alloc_page(image, GFP_KERNEL, KIMAGE_NO_DEST);
	       if (!page)
		       return -ENOMEM;

	       ind_page = page_address(page);
	       *image->entry = virt_to_boot_phys(ind_page) | IND_INDIRECTION;
	       image->entry = ind_page;
	       image->last_entry = ind_page +
				   ((PAGE_SIZE/sizeof(kimage_entry_t)) - 1);
       }
       *image->entry = entry;
       image->entry++;
       *image->entry = 0;

       return 0;
}

static int kimage_set_destination(struct kimage *image,
				 unsigned long destination)
{
       int result;

       destination &= PAGE_MASK;
       result = kimage_add_entry(image, destination | IND_DESTINATION);

       return result;
}


static int kimage_add_page(struct kimage *image, unsigned long page)
{
       int result;

       page &= PAGE_MASK;
       result = kimage_add_entry(image, page | IND_SOURCE);

       return result;
}


static void kimage_free_extra_pages(struct kimage *image)
{
       /* Walk through and free any extra destination pages I may have */
       kimage_free_page_list(&image->dest_pages);

       /* Walk through and free any unusable pages I have cached */
       kimage_free_page_list(&image->unusable_pages);

}
void kimage_terminate(struct kimage *image)
{
       if (*image->entry != 0)
	       image->entry++;

       *image->entry = IND_DONE;
}

#define for_each_kimage_entry(image, ptr, entry) \
       for (ptr = &image->head; (entry = *ptr) && !(entry & IND_DONE); \
	       ptr = (entry & IND_INDIRECTION) ? \
		       boot_phys_to_virt((entry & PAGE_MASK)) : ptr + 1)

static void kimage_free_entry(kimage_entry_t entry)
{
       struct page *page;

       page = boot_pfn_to_page(entry >> PAGE_SHIFT);
       kimage_free_pages(page);
}

void kimage_free(struct kimage *image)
{
       kimage_entry_t *ptr, entry;
       kimage_entry_t ind = 0;

       if (!image)
	       return;

       kimage_free_extra_pages(image);
       for_each_kimage_entry(image, ptr, entry) {
	       if (entry & IND_INDIRECTION) {
		       /* Free the previous indirection page */
		       if (ind & IND_INDIRECTION)
			       kimage_free_entry(ind);
		       /* Save this indirection page until we are
			* done with it.
			*/
		       ind = entry;
	       } else if (entry & IND_SOURCE)
		       kimage_free_entry(entry);
       }
       /* Free the final indirection page */
       if (ind & IND_INDIRECTION)
	       kimage_free_entry(ind);

       /* Handle any machine specific cleanup */
       machine_kexec_cleanup(image);

       /* Free the kexec control pages... */
       kimage_free_page_list(&image->control_pages);

       /*
	* Free up any temporary buffers allocated. This might hit if
	* error occurred much later after buffer allocation.
	*/
       if (image->file_mode)
	       kimage_file_post_load_cleanup(image);

       kfree(image);
}

static kimage_entry_t *kimage_dst_used(struct kimage *image,
				      unsigned long page)
{
       kimage_entry_t *ptr, entry;
       unsigned long destination = 0;

       for_each_kimage_entry(image, ptr, entry) {
	       if (entry & IND_DESTINATION)
		       destination = entry & PAGE_MASK;
	       else if (entry & IND_SOURCE) {
		       if (page == destination)
			       return ptr;
		       destination += PAGE_SIZE;
	       }
       }

       return NULL;
}

static struct page *kimage_alloc_page(struct kimage *image,
				     gfp_t gfp_mask,
				     unsigned long destination)
{
       /*
	* Here we implement safeguards to ensure that a source page
	* is not copied to its destination page before the data on
	* the destination page is no longer useful.
	*
	* To do this we maintain the invariant that a source page is
	* either its own destination page, or it is not a
	* destination page at all.
	*
	* That is slightly stronger than required, but the proof
	* that no problems will not occur is trivial, and the
	* implementation is simply to verify.
	*
	* When allocating all pages normally this algorithm will run
	* in O(N) time, but in the worst case it will run in O(N^2)
	* time.   If the runtime is a problem the data structures can
	* be fixed.
	*/
       struct page *page;
       unsigned long addr;

       /*
	* Walk through the list of destination pages, and see if I
	* have a match.
	*/
       list_for_each_entry(page, &image->dest_pages, lru) {
	       addr = page_to_boot_pfn(page) << PAGE_SHIFT;
	       if (addr == destination) {
		       list_del(&page->lru);
		       return page;
	       }
       }
       page = NULL;
       while (1) {
	       kimage_entry_t *old;

	       /* Allocate a page, if we run out of memory give up */
	       page = kimage_alloc_pages(gfp_mask, 0);
	       if (!page)
		       return NULL;
	       /* If the page cannot be used file it away */
	       if (page_to_boot_pfn(page) >
		   (KEXEC_SOURCE_MEMORY_LIMIT >> PAGE_SHIFT)) {
		       list_add(&page->lru, &image->unusable_pages);
		       continue;
	       }
	       addr = page_to_boot_pfn(page) << PAGE_SHIFT;

	       /* If it is the destination page we want use it */
	       if (addr == destination)
		       break;

	       /* If the page is not a destination page use it */
	       if (!kimage_is_destination_range(image, addr,
						addr + PAGE_SIZE))
		       break;

	       /*
		* I know that the page is someones destination page.
		* See if there is already a source page for this
		* destination page.  And if so swap the source pages.
		*/
	       old = kimage_dst_used(image, addr);
	       if (old) {
		       /* If so move it */
		       unsigned long old_addr;
		       struct page *old_page;

		       old_addr = *old & PAGE_MASK;
		       old_page = boot_pfn_to_page(old_addr >> PAGE_SHIFT);
		       copy_highpage(page, old_page);
		       *old = addr | (*old & ~PAGE_MASK);

		       /* The old page I have found cannot be a
			* destination page, so return it if it's
			* gfp_flags honor the ones passed in.
			*/
		       if (!(gfp_mask & __GFP_HIGHMEM) &&
			   PageHighMem(old_page)) {
			       kimage_free_pages(old_page);
			       continue;
		       }
		       addr = old_addr;
		       page = old_page;
		       break;
	       }
	       /* Place the page on the destination list, to be used later */
	       list_add(&page->lru, &image->dest_pages);
       }

       return page;
}

int kimage_load_segment(struct kimage *image,
			struct kexec_segment *segment)
{
       unsigned long maddr;
       size_t ubytes, mbytes;
       int result;
       unsigned char __user *buf = NULL;
       unsigned char *kbuf = NULL;

       result = 0;
       if (image->file_mode)
	       kbuf = segment->kbuf;
       else
	       buf = segment->buf;
       ubytes = segment->bufsz;
       mbytes = segment->memsz;
       maddr = segment->mem;

       result = kimage_set_destination(image, maddr);
       if (result < 0)
	       goto out;

       while (mbytes) {
	       struct page *page;
	       char *ptr;
	       size_t uchunk, mchunk;

	       page = kimage_alloc_page(image, GFP_HIGHUSER, maddr);
	       if (!page) {
		       result  = -ENOMEM;
		       goto out;
	       }
	       result = kimage_add_page(image, page_to_boot_pfn(page)
						       << PAGE_SHIFT);
	       if (result < 0)
		       goto out;

	       ptr = kmap(page);
	       /* Start with a clear page */
	       clear_page(ptr);
	       ptr += maddr & ~PAGE_MASK;
	       mchunk = min_t(size_t, mbytes,
			      PAGE_SIZE - (maddr & ~PAGE_MASK));
	       uchunk = min(ubytes, mchunk);

	       /* For file based kexec, source pages are in kernel memory */
	       if (image->file_mode)
		       memcpy(ptr, kbuf, uchunk);
	       else
		       result = copy_from_user(ptr, buf, uchunk);
	       kunmap(page);
	       if (result) {
		       result = -EFAULT;
		       goto out;
	       }
	       ubytes -= uchunk;
	       maddr  += mchunk;
	       if (image->file_mode)
		       kbuf += mchunk;
	       else
		       buf += mchunk;
	       mbytes -= mchunk;

	       cond_resched();
       }
out:
       return result;
}

struct kimage *kexec_image;
int kexec_load_disabled;

/*
 * Private qcom_glink layouts from the exact NHSS.QSDK.12.1.r3 source used by
 * Xiaomi's 5.4.164 Image.  They are views of objects owned by the stock
 * driver, never objects allocated by this module.  Compile-time offset checks
 * below make a build fail if the selected QSDK headers change their ABI.
 */
struct be7000_glink_rpm_pipe_view {
	size_t length;
	void *avail;
	void *peak;
	void *advance;
	void *write;
	void __iomem *tail;
	void __iomem *head;
	void __iomem *fifo;
};

struct be7000_qcom_glink_view {
	struct device *dev;
	const char *name;
	struct mbox_client mbox_client;
	struct mbox_chan *mbox_chan;
	struct be7000_glink_rpm_pipe_view *rx_pipe;
	struct be7000_glink_rpm_pipe_view *tx_pipe;
	int irq;
	struct work_struct rx_work;
	struct workqueue_struct *rx_wq;
	spinlock_t rx_lock;
	spinlock_t irq_lock;
	struct list_head rx_queue;
	spinlock_t tx_lock;
	spinlock_t idr_lock;
	struct idr lcids;
	struct idr rcids;
	unsigned long features;
	bool intentless;
	atomic_t id_advance;
};

struct be7000_glink_channel_view {
	u8 endpoint_and_rpdev[88];
	struct be7000_qcom_glink_view *glink;
	struct kref refcount;
	char *name;
	unsigned int lcid;
	unsigned int rcid;
};

/*
 * Do not use the build tree's inline dev_get_drvdata() here.  The exact stock
 * Image proves the platform drvdata load is pdev + 136; with struct device at
 * pdev + 16 this is device + 120.  Keeping the two fields we need in an
 * explicit binary view prevents an unrelated header ABI shim from silently
 * moving the access again.
 */
struct be7000_device_view {
	u8 opaque[104];
	struct device_driver *driver;
	void *platform_data;
	void *driver_data;
};

static void kexec_check_rpm_glink_layout(void)
{
	BUILD_BUG_ON(offsetof(struct be7000_glink_rpm_pipe_view, tail) != 40);
	BUILD_BUG_ON(offsetof(struct be7000_glink_rpm_pipe_view, head) != 48);
	BUILD_BUG_ON(offsetof(struct be7000_qcom_glink_view, rx_pipe) != 80);
	BUILD_BUG_ON(offsetof(struct be7000_qcom_glink_view, tx_pipe) != 88);
	BUILD_BUG_ON(offsetof(struct be7000_qcom_glink_view, irq) != 96);
	BUILD_BUG_ON(offsetof(struct be7000_qcom_glink_view, rx_work) != 104);
	BUILD_BUG_ON(offsetof(struct be7000_qcom_glink_view, rx_wq) != 136);
	BUILD_BUG_ON(offsetof(struct be7000_qcom_glink_view, rx_lock) != 144);
	BUILD_BUG_ON(offsetof(struct be7000_qcom_glink_view, rx_queue) != 152);
	BUILD_BUG_ON(offsetof(struct be7000_qcom_glink_view, tx_lock) != 168);
	BUILD_BUG_ON(offsetof(struct be7000_qcom_glink_view, idr_lock) != 172);
	BUILD_BUG_ON(offsetof(struct be7000_qcom_glink_view, lcids) != 176);
	BUILD_BUG_ON(offsetof(struct be7000_qcom_glink_view, rcids) != 200);
	BUILD_BUG_ON(offsetof(struct be7000_qcom_glink_view, features) != 224);
	BUILD_BUG_ON(offsetof(struct be7000_qcom_glink_view, intentless) != 232);
	BUILD_BUG_ON(offsetof(struct be7000_glink_channel_view, glink) != 88);
	BUILD_BUG_ON(offsetof(struct be7000_glink_channel_view, refcount) != 96);
	BUILD_BUG_ON(offsetof(struct be7000_glink_channel_view, name) != 104);
	BUILD_BUG_ON(offsetof(struct be7000_glink_channel_view, lcid) != 112);
	BUILD_BUG_ON(offsetof(struct be7000_glink_channel_view, rcid) != 116);
	BUILD_BUG_ON(offsetof(struct be7000_device_view, driver) != 104);
	BUILD_BUG_ON(offsetof(struct be7000_device_view, driver_data) != 120);
	BUILD_BUG_ON(offsetof(struct kexec_rpm_glink_handoff,
			      writer_stage) != 80);
	BUILD_BUG_ON(offsetof(struct kexec_rpm_glink_handoff,
			      reserved[0]) != 84);
	BUILD_BUG_ON(offsetof(struct kexec_rpm_glink_handoff,
			      reserved[1]) != 88);
	BUILD_BUG_ON(offsetof(struct kexec_rpm_glink_handoff,
			      reserved[2]) != 92);
	BUILD_BUG_ON(sizeof(struct kexec_rpm_glink_handoff) != 96);
}

static int kexec_count_rpm_glink_child(struct device *child, void *data)
{
	unsigned int *count = data;

	(*count)++;
	return 0;
}

static struct be7000_glink_channel_view *
kexec_find_rpm_channel(struct idr *channels, int *found_id)
{
	struct be7000_glink_channel_view *channel;
	int id = 1;

	while ((channel = idr_get_next(channels, &id))) {
		if (channel->name && !strcmp(channel->name, "rpm_requests")) {
			*found_id = id;
			return channel;
		}
		if (id == INT_MAX)
			break;
		id++;
	}

	return NULL;
}

static bool kexec_rpm_cursor_valid(u32 cursor, size_t length)
{
	return length && length <= U32_MAX && cursor < length && !(cursor & 7);
}

static int kexec_prepare_rpm_glink_handoff(void)
{
	struct device *dev;
	struct be7000_qcom_glink_view *glink;
	struct be7000_glink_rpm_pipe_view *rx;
	struct be7000_glink_rpm_pipe_view *tx;
	struct be7000_glink_channel_view *lc;
	struct be7000_glink_channel_view *rc;
	struct be7000_device_view *device_view;
	struct kexec_rpm_glink_handoff record = { };
	unsigned long irq_flags;
	unsigned int child_count = 0;
	int lcid = 0;
	int rcid = 0;
	int ret;

	kexec_check_rpm_glink_layout();
	kexec_rpm_glink_handoff_invalidate();

	/*
	 * Access only the pointers already mapped and owned by qcom_glink_rpm.
	 * No new mapping of RPM message RAM is made here.
	 */
	dev = bus_find_device_by_name(&platform_bus_type, NULL, "rpm-glink");
	if (!dev) {
		pr_err("rpm-glink platform device was not found for handoff\n");
		return -ENODEV;
	}
	device_view = (struct be7000_device_view *)dev;

	ret = device_for_each_child(dev, &child_count,
				    kexec_count_rpm_glink_child);
	if (ret || !device_view->driver || !child_count) {
		pr_err("rpm-glink is not ready for handoff: iterate=%d bound=%u children=%u\n",
			ret, !!device_view->driver, child_count);
		ret = ret ?: -ENODEV;
		goto out_put;
	}

	glink = device_view->driver_data;
	if (!glink || glink->dev != dev || !glink->intentless ||
	    glink->irq <= 0 || !glink->rx_pipe || !glink->tx_pipe) {
		pr_err("rpm-glink private state failed validation\n");
		ret = -EINVAL;
		goto out_put;
	}
	rx = glink->rx_pipe;
	tx = glink->tx_pipe;
	if (!rx->tail || !rx->head || !tx->tail || !tx->head ||
	    !rx->fifo || !tx->fifo) {
		pr_err("rpm-glink pipe pointers failed validation\n");
		ret = -EINVAL;
		goto out_put;
	}

	/* Drain deferred control work, then stop the old AP-side receiver. */
	flush_work(&glink->rx_work);
	disable_irq(glink->irq);
	synchronize_irq(glink->irq);
	flush_work(&glink->rx_work);

	spin_lock_irqsave(&glink->idr_lock, irq_flags);
	lc = kexec_find_rpm_channel(&glink->lcids, &lcid);
	rc = kexec_find_rpm_channel(&glink->rcids, &rcid);
	if (!lc || lc != rc || lc->glink != glink ||
	    lc->lcid != lcid || lc->rcid != rcid) {
		spin_unlock_irqrestore(&glink->idr_lock, irq_flags);
		pr_err("rpm_requests IDR state is not adoptable: lcid=%d rcid=%d same=%u\n",
			lcid, rcid, lc && lc == rc);
		ret = -EINVAL;
		goto out_put;
	}
	spin_unlock_irqrestore(&glink->idr_lock, irq_flags);

	spin_lock_irqsave(&glink->tx_lock, irq_flags);
	record.tx_tail = readl(tx->tail);
	record.tx_head = readl(tx->head);
	spin_unlock_irqrestore(&glink->tx_lock, irq_flags);
	record.rx_tail = readl(rx->tail);
	record.rx_head = readl(rx->head);

	if (record.tx_head != record.tx_tail ||
	    record.rx_head != record.rx_tail ||
	    !kexec_rpm_cursor_valid(record.tx_head, tx->length) ||
	    !kexec_rpm_cursor_valid(record.rx_head, rx->length) ||
	    lcid <= 0 || lcid >= 65536 || rcid <= 0 || rcid >= 65536) {
		pr_err("rpm-glink is not idle/adoptable: tx=%x/%x len=%zx rx=%x/%x len=%zx lcid=%d rcid=%d\n",
			record.tx_tail, record.tx_head, tx->length,
			record.rx_tail, record.rx_head, rx->length,
			lcid, rcid);
		ret = -EBUSY;
		goto out_put;
	}

	record.version = KEXEC_RPM_GLINK_HANDOFF_VERSION;
	record.size = sizeof(record);
	record.state = KEXEC_RPM_GLINK_HANDOFF_READY;
	record.state_inv = ~record.state;
	record.flags = KEXEC_RPM_GLINK_HANDOFF_IDLE;
	record.lcid = lcid;
	record.rcid = rcid;
	record.features = glink->features;
	record.tx_len = tx->length;
	record.rx_len = rx->length;
	strscpy(record.name, "rpm_requests", sizeof(record.name));
	record.writer_stage = 0x5200;

	ret = kexec_rpm_glink_handoff_publish(&record);
	if (ret) {
		pr_err("Unable to publish rpm-glink handoff: %d\n", ret);
		goto out_put;
	}

	pr_emerg("rpm-glink handoff ready: lcid=%u rcid=%u features=%#llx tx=%03x/%03x rx=%03x/%03x\n",
		record.lcid, record.rcid,
		(unsigned long long)record.features,
		record.tx_tail, record.tx_head,
		record.rx_tail, record.rx_head);
	ret = 0;

out_put:
	put_device(dev);
	return ret;
}

/*
 * Move into place and start executing a preloaded standalone
 * executable.  If nothing was preloaded return an error.
 */
int kernel_kexec(void)
{
       int error = 0;
	unsigned long cpu_mask_before = 0;
	unsigned long cpu_parked_mask = 0;

       if (!mutex_trylock(&kexec_mutex))
	       return -EBUSY;
       if (!kexec_image) {
	       error = -EINVAL;
	       goto Unlock;
       }

	{
	       /*
		* This module is entered directly from a live user-space process,
		* unlike the usual distro shutdown path.  The Xiaomi UBI/SquashFS
		* stack can otherwise keep issuing reads while device_shutdown()
		* and disable_nonboot_cpus() are already in progress.
		*/
	       pr_emerg("Freezing user space before device shutdown\n");
	       error = kexec_freeze_processes();
	       if (error) {
		       pr_err("Failed to freeze user space: %d\n", error);
		       goto Unlock;
	       }
	       kexec_breadcrumb_write(0x200);

	       /* Let already queued block/readahead work complete. */
	       msleep(500);
	       kexec_breadcrumb_write(0x210);

	       kexec_in_progress = true;
	       kexec_breadcrumb_write(0x220);

	       /* Keep every CPU powered until all device/RPM work is complete. */
	       migrate_to_reboot_cpu();
	       kexec_breadcrumb_write(0x240);
	       cpu_hotplug_enable();
	       kexec_breadcrumb_write(0x250);
	       cpu_mask_before = cpumask_bits(cpu_online_mask)[0];
	       if (cpu_mask_before != 0xf) {
		       kexec_breadcrumb_write_detail(0x25e, 0,
			       (u32)cpu_mask_before);
		       pr_emerg("Spin-table handoff requires CPUs 0-3 online; waiting for stock-boot watchdog reset\n");
		       while (1)
			       cpu_relax();
	       }
	       error = kexec_secondary_park_prepare();
	       if (error) {
		       kexec_breadcrumb_write_detail(0x25e, (u32)error,
			       (u32)cpu_mask_before);
		       pr_emerg("Secondary spin-table preparation failed (%d); waiting for stock-boot watchdog reset\n",
				error);
		       while (1)
			       cpu_relax();
	       }
	       kexec_breadcrumb_write_detail(0x252, 0,
		       ((u64)(u32)cpu_mask_before << 32) | 0x0e);

	       /* Device and RPM teardown still runs with all four CPUs alive. */
	       kernel_restart_prepare(NULL);
	       kexec_breadcrumb_write(0x230);
	       kexec_breadcrumb_write(0x235);
	       error = kexec_quiesce_pci();
	       if (error) {
		       kexec_breadcrumb_write(0x23f);
		       pr_emerg("PCI DMA could not be quiesced; waiting for stock-boot watchdog reset\n");
		       while (1)
			       cpu_relax();
	       }
	       kexec_breadcrumb_write(0x236);
	       kexec_breadcrumb_write(0x232);
	       error = kexec_prepare_rpm_glink_handoff();
	       if (error) {
		       kexec_breadcrumb_write(0x23e);
		       pr_emerg("RPM GLINK handoff failed (%d); waiting for stock-boot watchdog reset\n",
				error);
		       while (1)
			       cpu_relax();
	       }
	       kexec_breadcrumb_write(0x234);
	       /*
		* Do not power the secondary CPUs down through PSCI.  Move each one
		* through cpu_soft_restart into a physical spin-table pen and wait
		* until all three have acknowledged from the MMU-off state.  No
		* lock-taking operation is allowed after this point.
		*/
	       kexec_rpm_glink_handoff_set_cpu_state(KEXEC_CPU_HANDOFF_READY,
		       (u32)cpu_mask_before, 0, 0);
	       pr_emerg("Starting new kernel through secondary spin-table handoff\n");
	       kexec_breadcrumb_write(0x260);
	       error = kexec_secondary_park_cpus(cpu_mask_before,
						 &cpu_parked_mask);
	       if (error) {
		       kexec_breadcrumb_write_detail(0x25e, (u32)error,
			       ((u64)(u32)cpu_mask_before << 32) |
			       (u32)cpu_parked_mask);
		       while (1)
			       cpu_relax();
	       }
	       kexec_rpm_glink_handoff_set_cpu_state(KEXEC_CPU_HANDOFF_PARKED,
		       (u32)cpu_mask_before, (u32)cpu_parked_mask, 0);
	       kexec_breadcrumb_write_detail(0x268, 0,
		       ((u64)(u32)cpu_mask_before << 32) |
		       (u32)cpu_parked_mask);
	       kexec_breadcrumb_write(0x270);
       }

	 kexec_breadcrumb_write(0x280);
       machine_kexec(kexec_image);
Unlock:
       mutex_unlock(&kexec_mutex);
       return error;
}
