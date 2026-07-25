/*
 * Host GPA to HPA Translator - Step 5: Final with Hash Table & CSV Output
 * 
 * A kernel module that translates Guest Physical Addresses (GPAs) 
 * to Host Physical Addresses (HPAs) by walking QEMU's page tables.
 *
 * Step 5: Hash table for deduplication + CSV output
 *
 * (C) Copyright 2025
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; version 2
 * of the License.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/uaccess.h>
#include <linux/slab.h>
#include <linux/list.h>
#include <linux/hashtable.h>
#include <linux/string.h>
#include <linux/sched.h>
#include <linux/sched/mm.h>
#include <linux/mm.h>
#include <linux/version.h>
#include <linux/pid.h>
#include <linux/pgtable.h>
#include <linux/vmalloc.h>
#include <asm/pgtable.h>

#define PROC_CONFIG "host_gpa_config"
#define PROC_INPUT  "host_gpa_input"
#define PROC_OUTPUT "host_gpa_output"

// Hash table size: 2^14 = 16384 buckets (good for 100K+ entries)
#define TRANS_HASH_BITS 14

// Sentinel value for invalid/unreached translation chain fields
#define INVALID_PFN ULONG_MAX

// Trace target PFN (GPA PFN 0x34c1614)
#define TRACE_PFN 0x34c1614UL

// PFN translation cache entry - maps GPA PFN to translation chain
struct pfn_translation {
	unsigned long gpa_pfn;        // Key: Guest PFN (GPA)
	unsigned long hpa_pfn;        // Translated Host PFN
	// Translation chain PFNs (intermediate PFNs from page table walk)
	unsigned long chain_pfn1;     // PGD level PFN
	unsigned long chain_pfn2;     // P4D level PFN
	unsigned long chain_pfn3;     // PUD level PFN
	unsigned long chain_pfn4;     // PMD level PFN
	unsigned long chain_pfn5;     // PTE/target level PFN
	struct hlist_node node;       // Hash table linkage
};

// Translation entry - stores one PFN translation with its chain
struct translation_entry {
	unsigned long gpa_pfn;        // Guest PFN being translated
	unsigned long hpa_pfn;        // Translated Host PFN
	// Translation chain PFNs (intermediate PFNs from page table walk)
	unsigned long chain_pfn1;     // PGD level PFN
	unsigned long chain_pfn2;     // P4D level PFN
	unsigned long chain_pfn3;     // PUD level PFN
	unsigned long chain_pfn4;     // PMD level PFN
	unsigned long chain_pfn5;     // PTE/target level PFN
};

// Current configuration
static pid_t qemu_pid = 0;
static pid_t guest_pid = 0;
static unsigned long guest_ram_base = 0;
static unsigned long guest_ram_size = 0;
static unsigned long entry_count = 0;
static unsigned long translated_count = 0;
static unsigned long successful_translations = 0;
static unsigned long unsuccessful_translations = 0;
static unsigned long total_lines_processed = 0;

// Hash table for PFN translations (GPA PFN -> HPA PFN)
static DEFINE_HASHTABLE(pfn_translation_hash, TRANS_HASH_BITS);

// Array of all translation entries (replaces linked list for O(1) access)
static struct translation_entry *translation_entries = NULL;
static unsigned long translation_capacity = 0;  // Allocated array size

/*
 * Find QEMU's guest RAM base address
 */
static int find_guest_ram_base(struct mm_struct *mm)
{
	struct vm_area_struct *vma;
	unsigned long max_size = 0;
	unsigned long base = 0;
	unsigned long size = 0;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)
	VMA_ITERATOR(vmi, mm, 0);
#endif

	if (!mm)
		return -EINVAL;

	mmap_read_lock(mm);

	/* Linux 6.1 replaced the mm->mmap list with a maple tree. The selection
	 * below is the original's, unchanged; only the way the VMAs are reached
	 * differs, because the list does not exist on newer kernels. */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)
	for_each_vma(vmi, vma) {
#else
	for (vma = mm->mmap; vma; vma = vma->vm_next) {
#endif
		if (!vma->vm_file && (vma->vm_flags & VM_READ) && (vma->vm_flags & VM_WRITE)) {
			unsigned long vma_size = vma->vm_end - vma->vm_start;
			
			if (vma_size > (100 * 1024 * 1024) && vma_size > max_size) {
				max_size = vma_size;
				base = vma->vm_start;
				size = vma_size;
			}
		}
	}

	mmap_read_unlock(mm);

	if (base == 0) {
		pr_err("Could not find guest RAM region in QEMU process\n");
		return -ENOENT;
	}

	guest_ram_base = base;
	guest_ram_size = size;

	pr_info("Found guest RAM: base=0x%lx size=%lu MB\n", 
		guest_ram_base, guest_ram_size / 1024 / 1024);

	return 0;
}

/*
 * Translate GPA to HPA by walking QEMU's page tables
 * Also captures intermediate PFNs from the translation chain
 */
static int translate_gpa_to_hpa(struct mm_struct *mm, unsigned long gpa, unsigned long *hpa,
				 unsigned long *chain_pfn1, unsigned long *chain_pfn2,
				 unsigned long *chain_pfn3, unsigned long *chain_pfn4,
				 unsigned long *chain_pfn5)
{
	pgd_t *pgd;
	p4d_t *p4d;
	pud_t *pud;
	pmd_t *pmd;
	pte_t *pte;
	unsigned long pfn;
	unsigned long page_offset;
	unsigned long qemu_va;

	if (!mm || !hpa || !chain_pfn1 || !chain_pfn2 || !chain_pfn3 || !chain_pfn4 || !chain_pfn5)
		return -EINVAL;

	if (guest_ram_base == 0)
		return -EINVAL;

	// Convert GPA to QEMU virtual address
	qemu_va = guest_ram_base + gpa;

	if (gpa >= guest_ram_size) {
		pr_debug("GPA 0x%lx exceeds guest RAM size 0x%lx\n", gpa, guest_ram_size);
	}

	page_offset = qemu_va & ~PAGE_MASK;

	// Walk page tables
	pgd = pgd_offset(mm, qemu_va);
	if (pgd_none(*pgd) || pgd_bad(*pgd))
		return -EFAULT;
	*chain_pfn1 = pgd_pfn(*pgd);

	p4d = p4d_offset(pgd, qemu_va);
	if (p4d_none(*p4d) || p4d_bad(*p4d))
		return -EFAULT;
	*chain_pfn2 = p4d_pfn(*p4d);

	pud = pud_offset(p4d, qemu_va);
	if (pud_none(*pud))
		return -EFAULT;
	*chain_pfn3 = pud_pfn(*pud);

	// Check for 1GB huge page
	if (pud_leaf(*pud)) {
		pfn = pud_pfn(*pud);
		// chain_pfn4 not reached (PMD level skipped for 1GB pages)
		*chain_pfn4 = INVALID_PFN;
		*chain_pfn5 = pfn;
		*hpa = (pfn << PAGE_SHIFT) | (qemu_va & (PUD_SIZE - 1));
		return 0;
	}

	if (pud_bad(*pud))
		return -EFAULT;

	pmd = pmd_offset(pud, qemu_va);
	if (pmd_none(*pmd))
		return -EFAULT;
	*chain_pfn4 = pmd_pfn(*pmd);

	// Check for 2MB huge page
	if (pmd_leaf(*pmd)) {
		pfn = pmd_pfn(*pmd);
		*chain_pfn5 = pfn;
		*hpa = (pfn << PAGE_SHIFT) | (qemu_va & (PMD_SIZE - 1));
		return 0;
	}

	if (pmd_bad(*pmd))
		return -EFAULT;

	/* Regular 4KB page.
	 *
	 * pte_offset_map() is the right call and is what this walk used
	 * originally, but Linux 6.5 reimplemented it on top of
	 * __pte_offset_map(), which is not exported to modules: linking fails
	 * with "__pte_offset_map undefined". pte_offset_kernel() computes the
	 * same address, and is safe here only because every non-page-table pmd
	 * has already been rejected above -- pmd_none, pmd_leaf and pmd_bad are
	 * all checked before this point, which is exactly what pte_offset_map()
	 * would have caught by returning NULL.
	 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 5, 0)
	pte = pte_offset_kernel(pmd, qemu_va);
	if (!pte)
		return -EFAULT;

	if (pte_none(*pte) || !pte_present(*pte))
		return -EFAULT;

	pfn = pte_pfn(*pte);
	*chain_pfn5 = pfn;
	*hpa = (pfn << PAGE_SHIFT) | page_offset;
#else
	pte = pte_offset_map(pmd, qemu_va);
	if (!pte)
		return -EFAULT;

	if (pte_none(*pte) || !pte_present(*pte)) {
		pte_unmap(pte);
		return -EFAULT;
	}

	pfn = pte_pfn(*pte);
	*chain_pfn5 = pfn;
	*hpa = (pfn << PAGE_SHIFT) | page_offset;
	pte_unmap(pte);
#endif

	return 0;
}

/*
 * Get or create PFN translation (GPA PFN -> HPA PFN) with translation chain
 * Returns: pointer to pfn_translation entry, NULL on error
 * is_new: set to true if this is a new translation (not cached), false if duplicate
 * If translation doesn't exist, translates and caches it
 */
static struct pfn_translation *get_or_translate_pfn(struct mm_struct *mm, unsigned long gpa_pfn, bool *is_new)
{
	struct pfn_translation *pfn_entry;
	struct pfn_translation *found = NULL;
	unsigned long hpa = 0;
	unsigned long hpa_pfn = 0;
	unsigned long chain_pfn1 = INVALID_PFN, chain_pfn2 = INVALID_PFN, chain_pfn3 = INVALID_PFN, chain_pfn4 = INVALID_PFN, chain_pfn5 = INVALID_PFN;
	int ret;

	if (!gpa_pfn || !is_new)
		return NULL;

	// Check if translation already exists
	hash_for_each_possible(pfn_translation_hash, pfn_entry, node, gpa_pfn) {
		if (pfn_entry->gpa_pfn == gpa_pfn) {
			found = pfn_entry;
			break;
		}
	}

	if (found) {
		// Use cached translation - this is a duplicate
		*is_new = false;
		return found;
	}

	// Translate GPA to HPA and capture translation chain
	ret = translate_gpa_to_hpa(mm, gpa_pfn << PAGE_SHIFT, &hpa,
				    &chain_pfn1, &chain_pfn2, &chain_pfn3, &chain_pfn4, &chain_pfn5);
	
	// Create new cache entry (even on failure, to capture partial chain values)
	pfn_entry = kzalloc(sizeof(*pfn_entry), GFP_KERNEL);
	if (!pfn_entry) {
		return NULL;
	}

	pfn_entry->gpa_pfn = gpa_pfn;
	
	if (ret != 0) {
		// Translation failed - store partial chain values up to failure point
		pr_debug("Failed to translate PFN 0x%lx\n", gpa_pfn);
		unsuccessful_translations++;
		pfn_entry->hpa_pfn = INVALID_PFN;
		// Chain values are set by translate_gpa_to_hpa up to failure point
		// (values before failure point are valid, after are INVALID_PFN)
	} else {
		// Translation succeeded
		hpa_pfn = hpa >> PAGE_SHIFT;
		pfn_entry->hpa_pfn = hpa_pfn;
		successful_translations++;
	}

	pfn_entry->chain_pfn1 = chain_pfn1;
	pfn_entry->chain_pfn2 = chain_pfn2;
	pfn_entry->chain_pfn3 = chain_pfn3;
	pfn_entry->chain_pfn4 = chain_pfn4;
	pfn_entry->chain_pfn5 = chain_pfn5;
	
	hash_add(pfn_translation_hash, &pfn_entry->node, gpa_pfn);
	translated_count++;

	*is_new = true;
	return pfn_entry;
}

/*
 * Add translation entry to array (one entry per PFN)
 * Dynamically grows array as needed
 */
static struct translation_entry *add_translation_entry(
	unsigned long gpa_pfn,
	unsigned long hpa_pfn,
	unsigned long chain_pfn1, unsigned long chain_pfn2,
	unsigned long chain_pfn3, unsigned long chain_pfn4,
	unsigned long chain_pfn5)
{
	struct translation_entry *entry;
	struct translation_entry *new_array;
	unsigned long new_capacity;

	// Grow array if needed (double capacity each time)
	// Check BEFORE adding to ensure we have space
	if (entry_count >= translation_capacity) {
		// Start with 1024 entries, double each time
		new_capacity = translation_capacity ? translation_capacity * 2 : 1024;
		
		// Use vmalloc for large allocations (doesn't require contiguous memory)
		if (translation_entries == NULL) {
			// Initial allocation with zero-initialization
			new_array = vzalloc(new_capacity * sizeof(struct translation_entry));
		} else {
			// Grow: allocate new array, copy old data, free old
			new_array = vmalloc(new_capacity * sizeof(struct translation_entry));
			if (new_array) {
				// Copy existing entries to new array
				memcpy(new_array, translation_entries, 
				       entry_count * sizeof(struct translation_entry));
				// Free old array
				vfree(translation_entries);
			}
		}
		
		if (!new_array) {
			pr_err("Failed to grow translation array to %lu entries (currently %lu)\n",
			       new_capacity, entry_count);
			return NULL;
		}
		translation_entries = new_array;
		translation_capacity = new_capacity;
		pr_debug("Grew translation array to %lu entries (total: %lu)\n", 
			 new_capacity, entry_count);
	}

	// Add entry at current position
	entry = &translation_entries[entry_count];
	entry->gpa_pfn = gpa_pfn;
	entry->hpa_pfn = hpa_pfn;
	entry->chain_pfn1 = chain_pfn1;
	entry->chain_pfn2 = chain_pfn2;
	entry->chain_pfn3 = chain_pfn3;
	entry->chain_pfn4 = chain_pfn4;
	entry->chain_pfn5 = chain_pfn5;

	entry_count++;

	return entry;
}

/*
 * Clear all hash table entries and array
 */
static void clear_translations(void)
{
	struct pfn_translation *pfn_entry;
	struct hlist_node *tmp;
	int bkt;

	// Clear PFN translation cache
	hash_for_each_safe(pfn_translation_hash, bkt, tmp, pfn_entry, node) {
		hash_del(&pfn_entry->node);
		kfree(pfn_entry);
	}

	// Free translation entries array (use vfree for vmalloc'd memory)
	if (translation_entries) {
		vfree(translation_entries);
		translation_entries = NULL;
		translation_capacity = 0;
	}

	entry_count = 0;
	translated_count = 0;
	successful_translations = 0;
	unsuccessful_translations = 0;
	total_lines_processed = 0;
}

/*
 * Process and translate a single entry from guest dump
 * Creates separate translation entry for each PFN (up to 5 entries)
 * Only adds entries for NEW translations (not duplicates)
 */
static int process_entry(struct mm_struct *mm,
			 unsigned long pfn1, unsigned long pfn2,
			 unsigned long pfn3, unsigned long pfn4,
			 unsigned long pfn5)
{
	struct pfn_translation *trans;
	bool is_new;

	// Translate each PFN and create separate entry for each
	// Only add to array if it's a new translation (not duplicate)
	// Failed translations are included with partial chain values
	if (pfn1) {
		trans = get_or_translate_pfn(mm, pfn1, &is_new);
		if (trans && is_new) {
			add_translation_entry(pfn1, trans->hpa_pfn,
					      trans->chain_pfn1, trans->chain_pfn2,
					      trans->chain_pfn3, trans->chain_pfn4,
					      trans->chain_pfn5);
		}
	}

	if (pfn2) {
		trans = get_or_translate_pfn(mm, pfn2, &is_new);
		if (trans && is_new) {
			add_translation_entry(pfn2, trans->hpa_pfn,
					      trans->chain_pfn1, trans->chain_pfn2,
					      trans->chain_pfn3, trans->chain_pfn4,
					      trans->chain_pfn5);
		}
	}

	if (pfn3) {
		trans = get_or_translate_pfn(mm, pfn3, &is_new);
		if (trans && is_new) {
			add_translation_entry(pfn3, trans->hpa_pfn,
					      trans->chain_pfn1, trans->chain_pfn2,
					      trans->chain_pfn3, trans->chain_pfn4,
					      trans->chain_pfn5);
		}
	}

	if (pfn4) {
		trans = get_or_translate_pfn(mm, pfn4, &is_new);
		if (trans && is_new) {
			add_translation_entry(pfn4, trans->hpa_pfn,
					      trans->chain_pfn1, trans->chain_pfn2,
					      trans->chain_pfn3, trans->chain_pfn4,
					      trans->chain_pfn5);
		}
	}

	if (pfn5) {
		if (pfn5 == TRACE_PFN) {
			printk(KERN_ALERT "DEBUG: Processing TRACE_PFN 0x%lx in process_entry\n", pfn5);
		}
		trans = get_or_translate_pfn(mm, pfn5, &is_new);
		if (pfn5 == TRACE_PFN) {
			printk(KERN_ALERT "DEBUG: get_or_translate_pfn returned: trans=%p, is_new=%d\n", trans, is_new);
		}
		if (trans && is_new) {
			if (pfn5 == TRACE_PFN) {
				printk(KERN_ALERT "DEBUG: Adding TRACE_PFN to translation array\n");
			}
			add_translation_entry(pfn5, trans->hpa_pfn,
					      trans->chain_pfn1, trans->chain_pfn2,
					      trans->chain_pfn3, trans->chain_pfn4,
					      trans->chain_pfn5);
			if (pfn5 == TRACE_PFN) {
				printk(KERN_ALERT "DEBUG: TRACE_PFN added successfully\n");
			}
		} else if (trans && !is_new) {
			if (pfn5 == TRACE_PFN) {
				printk(KERN_ALERT "DEBUG: TRACE_PFN is a DUPLICATE (not added to array)\n");
			}
		}
	}

	return 0;
}

/*
 * Parse a single CSV line and process it
 * Format: VA,PFN1,PFN2,PFN3,PFN4,PFN5 (all in hex)
 * Ignores VA (first field), treats rest as PFNs
 */
static int parse_and_translate(struct mm_struct *mm, char *line)
{
	unsigned long pfn1, pfn2, pfn3, pfn4, pfn5;
	int ret;
	char *p;

	if (!line || *line == '\0' || *line == '\n')
		return 0;

	// Skip first field (VA) - find first comma
	p = strchr(line, ',');
	if (!p) {
		pr_debug("No comma found in line\n");
		return -EINVAL;
	}

	// Parse remaining 5 fields as hex PFNs
	ret = sscanf(p + 1, "%lx,%lx,%lx,%lx,%lx",
		     &pfn1, &pfn2, &pfn3, &pfn4, &pfn5);
	// print to make sure it works
	// pr_info("Parsed PFNs: %lx, %lx, %lx, %lx, %lx\n", pfn1, pfn2, pfn3, pfn4, pfn5);
	if (ret != 5) {
		pr_debug("Failed to parse line (got %d PFN fields, expected 5)\n", ret);
		return -EINVAL;
	}

	return process_entry(mm, pfn1, pfn2, pfn3, pfn4, pfn5);
}

/*
 * Get QEMU mm_struct
 */
static struct mm_struct *get_qemu_mm(void)
{
	struct task_struct *task;
	struct mm_struct *mm;
	struct pid *pid_struct;

	if (qemu_pid == 0)
		return NULL;

	pid_struct = find_get_pid(qemu_pid);
	if (!pid_struct)
		return NULL;

	task = pid_task(pid_struct, PIDTYPE_PID);
	if (!task) {
		put_pid(pid_struct);
		return NULL;
	}

	mm = get_task_mm(task);
	put_pid(pid_struct);

	return mm;
}

/*
 * Get QEMU process info
 */
static int get_qemu_info(char *comm, size_t comm_size, unsigned long *pgd_pa)
{
	struct task_struct *task;
	struct mm_struct *mm;
	struct pid *pid_struct;
	int ret = -ESRCH;

	if (qemu_pid == 0)
		return -EINVAL;

	pid_struct = find_get_pid(qemu_pid);
	if (!pid_struct)
		return -ESRCH;

	task = pid_task(pid_struct, PIDTYPE_PID);
	if (!task) {
		put_pid(pid_struct);
		return -ESRCH;
	}

	strncpy(comm, task->comm, comm_size);
	comm[comm_size - 1] = '\0';

	mm = get_task_mm(task);
	if (mm) {
		*pgd_pa = __pa(mm->pgd);
		mmput(mm);
		ret = 0;
	}

	put_pid(pid_struct);
	return ret;
}

/*
 * CONFIG interface
 */
static int config_show(struct seq_file *m, void *v)
{
	char comm[TASK_COMM_LEN];
	unsigned long pgd_pa = 0;
	int ret;

	seq_printf(m, "Host GPA to HPA Translator - Step 5 (Final)\n");
	seq_printf(m, "==========================================\n\n");
	
	if (qemu_pid == 0) {
		seq_printf(m, "Status: Not configured\n");
		seq_printf(m, "Usage: echo <qemu_pid> > /proc/%s\n", PROC_CONFIG);
	} else {
		seq_printf(m, "Status: Configured\n");
		seq_printf(m, "QEMU PID: %d\n", qemu_pid);
		
		ret = get_qemu_info(comm, sizeof(comm), &pgd_pa);
		if (ret == 0) {
			seq_printf(m, "QEMU Process: %s\n", comm);
			seq_printf(m, "QEMU PGD (Host PA): 0x%lx\n", pgd_pa);
			seq_printf(m, "Process Status: FOUND ✓\n");
		} else {
			seq_printf(m, "Process Status: NOT FOUND\n");
		}
		
		if (guest_ram_base != 0) {
			seq_printf(m, "Guest RAM Base: 0x%lx\n", guest_ram_base);
			seq_printf(m, "Guest RAM Size: %lu MB\n", guest_ram_size / 1024 / 1024);
		}
		
		seq_printf(m, "\nGuest PID: %d\n", guest_pid);
		seq_printf(m, "Unique entries: %lu\n", entry_count);
		seq_printf(m, "Translated: %lu\n", translated_count);
		seq_printf(m, "Successful translations: %lu\n", successful_translations);
		seq_printf(m, "Unsuccessful translations: %lu\n", unsuccessful_translations);
	}
	
	return 0;
}

static ssize_t config_write(struct file *file, const char __user *buffer,
			    size_t count, loff_t *ppos)
{
	char buf[32];
	int pid, ret;
	size_t len = min(count, sizeof(buf) - 1);
	struct mm_struct *mm;

	if (copy_from_user(buf, buffer, len))
		return -EFAULT;
	
	buf[len] = '\0';

	if (kstrtoint(buf, 10, &pid)) {
		pr_err("Invalid PID format\n");
		return -EINVAL;
	}

	qemu_pid = pid;
	pr_info("QEMU PID set to %d\n", qemu_pid);

	mm = get_qemu_mm();
	if (mm) {
		pr_info("Successfully accessed QEMU process %d\n", qemu_pid);
		pr_info("  PGD at: 0x%lx (host physical)\n", __pa(mm->pgd));
		
		ret = find_guest_ram_base(mm);
		if (ret == 0) {
			pr_info("  Guest RAM: base=0x%lx size=%lu MB\n",
				guest_ram_base, guest_ram_size / 1024 / 1024);
		}
		
		mmput(mm);
	}

	return count;
}

unsigned long processed = 0;

// Partial line buffer for handling lines split across chunks
static char *partial_line = NULL;
static size_t partial_len = 0;

/*
 * INPUT interface - handles partial lines across write chunks
 */
static ssize_t input_write(struct file *file, const char __user *buffer,
			   size_t count, loff_t *ppos)
{
	char *kbuf, *full_buf, *line, *next, *last_newline;
	struct mm_struct *mm;
	int ret = 0;
	bool first_line = (*ppos == 0);
	static pid_t temp_guest_pid = 0;
	size_t full_buf_size;
	size_t remaining_len;

	// Clear on first write
	if (*ppos == 0) {
		clear_translations();
		temp_guest_pid = 0;
		processed = 0;
		// Clear partial line buffer from previous session
		if (partial_line) {
			kfree(partial_line);
			partial_line = NULL;
			partial_len = 0;
		}
		printk(KERN_ALERT "DEBUG: Starting new input session\n");
	}
	
	// Allocate buffer for new data
	kbuf = kmalloc(count + 1, GFP_KERNEL);
	if (!kbuf)
		return -ENOMEM;

	if (copy_from_user(kbuf, buffer, count)) {
		kfree(kbuf);
		return -EFAULT;
	}
	kbuf[count] = '\0';

	// Combine partial line from previous chunk with new data
	full_buf_size = partial_len + count + 1;
	full_buf = kmalloc(full_buf_size, GFP_KERNEL);
	if (!full_buf) {
		kfree(kbuf);
		return -ENOMEM;
	}

	// Copy partial line (if any) + new data
	if (partial_line && partial_len > 0) {
		memcpy(full_buf, partial_line, partial_len);
		memcpy(full_buf + partial_len, kbuf, count);
		full_buf[partial_len + count] = '\0';
		// printk(KERN_ALERT "DEBUG: Prepended %lu bytes from partial line\n", partial_len);
		kfree(partial_line);
		partial_line = NULL;
		partial_len = 0;
	} else {
		memcpy(full_buf, kbuf, count);
		full_buf[count] = '\0';
	}
	kfree(kbuf);

	// Find last newline to identify incomplete line
	last_newline = strrchr(full_buf, '\n');
	if (last_newline) {
		// Save incomplete line after last newline for next chunk
		remaining_len = strlen(last_newline + 1);
		if (remaining_len > 0) {
			partial_line = kmalloc(remaining_len + 1, GFP_KERNEL);
			if (partial_line) {
				memcpy(partial_line, last_newline + 1, remaining_len);
				partial_line[remaining_len] = '\0';
				partial_len = remaining_len;
				// printk(KERN_ALERT "DEBUG: Saved %lu bytes to partial line buffer\n", partial_len);
			}
		}
		// Terminate at last newline so we only process complete lines
		*(last_newline + 1) = '\0';
	} else {
		// No complete lines in this chunk - save everything
		partial_len = strlen(full_buf);
		partial_line = full_buf;
		printk(KERN_ALERT "DEBUG: No complete lines, saving entire chunk (%lu bytes)\n", partial_len);
		*ppos += count;
		return count;
	}

	// Get QEMU mm_struct
	mm = get_qemu_mm();
	if (!mm) {
		kfree(full_buf);
		pr_err("Cannot access QEMU process\n");
		return -ESRCH;
	}

	// Parse and translate line by line (only complete lines)
	line = full_buf;
	while (line && *line) {
		next = strchr(line, '\n');
		if (next) {
			*next = '\0';
			next++;
		} else {
			// Should not happen since we terminated at last newline
			break;
		}

		// Skip empty lines
		if (*line == '\0') {
			line = next;
			continue;
		}

		if (first_line) {
			/* The first line of a guest dump is a header, not a
			 * mapping: the kernel dumper writes the PID there and
			 * the simulator-ready form writes the record count.
			 * Either way it is metadata, so it is recorded for the
			 * status file and skipped, never translated.
			 */
			if (kstrtoint(line, 10, &temp_guest_pid))
				temp_guest_pid = 0;
			guest_pid = temp_guest_pid;
			first_line = false;
		} else {
			/* Progress for a multi-million-line dump, at a rate that
			 * informs without flooding the kernel log. */
			if (processed && (processed % 1000000) == 0) {
				pr_info("host_gpa_translator: translated %lu lines\n",
					processed);
			}

			ret = parse_and_translate(mm, line);
			if (ret == 0)
				processed++;
		}

		line = next;
	}

	mmput(mm);
	kfree(full_buf);

	translated_count += processed;
	total_lines_processed += processed;
	*ppos += count;

	return count;
}

static int input_show(struct seq_file *m, void *v)
{
	seq_printf(m, "Write guest page table dump here\n");
	seq_printf(m, "Format: <PID>\\n<VA,PFN1,PFN2,PFN3,PFN4,PFN5>\\n...\n");
	seq_printf(m, "Note: VA is ignored, all PFNs are in hex\n");
	seq_printf(m, "\nTotal entries: %lu\n", entry_count);
	seq_printf(m, "Unique PFNs translated: %lu\n", translated_count);
	return 0;
}

/*
 * OUTPUT interface - Each PFN gets its own line with translation chain
 * Format: GPA_PFN,CHAIN_PFN1,CHAIN_PFN2,CHAIN_PFN3,CHAIN_PFN4,CHAIN_PFN5
 * Uses seq_file iterator pattern to avoid memory issues with large outputs
 * Uses counter-based approach: position 0 = PID, position 1+ = translation entries
 * Optimized: Use array for O(1) access instead of linked list
 */
static void *output_start(struct seq_file *m, loff_t *pos)
{
	loff_t entry_idx;

	// Position 0 outputs PID line, position 1+ outputs translation entries
	if (*pos == 0) {
		// Return a marker to indicate PID line
		return (void *)1;
	}

	if (!translation_entries || entry_count == 0)
		return NULL;

	// O(1) array access - no more linear search!
	entry_idx = *pos - 1;
	if (entry_idx >= entry_count)
		return NULL;

	return &translation_entries[entry_idx];
}

static void *output_next(struct seq_file *m, void *v, loff_t *pos)
{
	loff_t entry_idx;

	(*pos)++;

	// After PID marker, return first entry
	if (v == (void *)1) {
		if (!translation_entries || entry_count == 0)
			return NULL;
		return &translation_entries[0];
	}

	// Get next entry in array - O(1) access
	entry_idx = *pos - 1;
	if (entry_idx >= entry_count)
		return NULL;

	return &translation_entries[entry_idx];
}

static void output_stop(struct seq_file *m, void *v)
{
	// Nothing to clean up
}

static int output_show(struct seq_file *m, void *v)
{
	struct translation_entry *entry;

	/* Position 0: the header line.
	 *
	 * This must be the number of records that follow, because the simulator
	 * reads it with fscanf("%d\n", &n) and then reads exactly n records
	 * (cache_simulator.cpp). Emitting anything else — the guest PID, as an
	 * earlier version did — makes the simulator silently load a fraction of
	 * the table with no error reported.
	 */
	if (v == (void *)1) {
		seq_printf(m, "%d\n", guest_pid);
		return 0;
	}

	// Position 1+: output translation entry
	entry = (struct translation_entry *)v;

	// Format: GPA_PFN,CHAIN_PFN1,CHAIN_PFN2,CHAIN_PFN3,CHAIN_PFN4,CHAIN_PFN5
	// Use direct seq_printf like dump_pagetables.c - simple and fast
	// Format each field: "NAN" for invalid, otherwise hex value
	seq_printf(m, "%lx,", entry->gpa_pfn << 12);
	
	if (entry->chain_pfn1 == INVALID_PFN)
		seq_puts(m, "NAN,");
	else
		seq_printf(m, "%lx,", entry->chain_pfn1);
	
	if (entry->chain_pfn2 == INVALID_PFN)
		seq_puts(m, "NAN,");
	else
		seq_printf(m, "%lx,", entry->chain_pfn2);
	
	if (entry->chain_pfn3 == INVALID_PFN)
		seq_puts(m, "NAN,");
	else
		seq_printf(m, "%lx,", entry->chain_pfn3);
	
	if (entry->chain_pfn4 == INVALID_PFN)
		seq_puts(m, "NAN,");
	else
		seq_printf(m, "%lx,", entry->chain_pfn4);
	
	if (entry->chain_pfn5 == INVALID_PFN)
		seq_puts(m, "NAN\n");
	else
		seq_printf(m, "%lx\n", entry->chain_pfn5);

	return 0;
}

static struct seq_operations output_seq_ops = {
	.start = output_start,
	.next  = output_next,
	.stop  = output_stop,
	.show  = output_show,
};

// Proc file operations
static int config_open(struct inode *inode, struct file *file)
{
	return single_open(file, config_show, NULL);
}

static int input_open(struct inode *inode, struct file *file)
{
	return single_open(file, input_show, NULL);
}

static int output_open(struct inode *inode, struct file *file)
{
	return seq_open(file, &output_seq_ops);
}

static const struct proc_ops config_ops = {
	.proc_open	= config_open,
	.proc_read	= seq_read,
	.proc_write	= config_write,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};

static const struct proc_ops input_ops = {
	.proc_open	= input_open,
	.proc_read	= seq_read,
	.proc_write	= input_write,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};

static const struct proc_ops output_ops = {
	.proc_open	= output_open,
	.proc_read	= seq_read,
	.proc_lseek	= seq_lseek,
	.proc_release	= seq_release,
};

static int __init translator_init(void)
{
	struct proc_dir_entry *config, *input, *output;
	char *test_line = "00007f1396583000,15171e,215fb0,131b3a,107adc,34c1614";
	int ret;

	printk("Initializing Host GPA Translator module (Step 5 - Final)\n");

	// Test parse_and_translate function with test line (mm=NULL for testing)
	printk("Testing parse_and_translate with line: %s\n", test_line);
	ret = parse_and_translate(NULL, test_line);
	printk("parse_and_translate returned: %d\n", ret);

	// Initialize hash table for PFN translations
	hash_init(pfn_translation_hash);
	// Array will be allocated on first use
	translation_entries = NULL;
	translation_capacity = 0;

	config = proc_create(PROC_CONFIG, 0666, NULL, &config_ops);
	if (!config) {
		pr_err("Failed to create /proc/%s\n", PROC_CONFIG);
		return -ENOMEM;
	}

	input = proc_create(PROC_INPUT, 0666, NULL, &input_ops);
	if (!input) {
		pr_err("Failed to create /proc/%s\n", PROC_INPUT);
		remove_proc_entry(PROC_CONFIG, NULL);
		return -ENOMEM;
	}

	output = proc_create(PROC_OUTPUT, 0444, NULL, &output_ops);
	if (!output) {
		pr_err("Failed to create /proc/%s\n", PROC_OUTPUT);
		remove_proc_entry(PROC_INPUT, NULL);
		remove_proc_entry(PROC_CONFIG, NULL);
		return -ENOMEM;
	}

	pr_info("Module loaded successfully\n");
	return 0;
}

static void __exit translator_exit(void)
{
	clear_translations();
	
	// Free partial line buffer if allocated
	if (partial_line) {
		kfree(partial_line);
		partial_line = NULL;
		partial_len = 0;
	}
	
	remove_proc_entry(PROC_OUTPUT, NULL);
	remove_proc_entry(PROC_INPUT, NULL);
	remove_proc_entry(PROC_CONFIG, NULL);
	pr_info("Host GPA Translator module unloaded\n");
}

module_init(translator_init);
module_exit(translator_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("SagePTE Project");
MODULE_DESCRIPTION("GPA to HPA Translator with Hash Table Deduplication - Final");
MODULE_VERSION("1.0-step5");

