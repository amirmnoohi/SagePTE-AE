/*
 * =============================================================================
 *  SagePTE Artifact - Host Page-Table Augmentor
 * =============================================================================
 *
 *  SYNOPSIS
 *      host_pt_augmentor <raw-host-page-table> <output>
 *
 *  DESCRIPTION
 *      Post-processes the raw output of the host_gpa_translator module into the
 *      form the simulator can replay. It is a required stage, not an
 *      optimisation: the raw output cannot be loaded as it stands.
 *
 *  WHY IT IS REQUIRED
 *      1. NAN fields. The translator writes "NAN" for a page-table level that
 *         does not exist for a given guest frame - a mapping that terminates
 *         early at a huge page, for instance. The simulator parses every field
 *         with %llx (cache_simulator.cpp), which cannot read "NAN": the
 *         conversion fails and the field is left holding whatever was in the
 *         struct, silently corrupting that entry.
 *
 *         Each NAN is therefore replaced with a *unique, unallocated* PFN -
 *         one drawn from the gaps between the PFNs the dump actually uses. The
 *         value is deliberately one that no real mapping owns, so the walk step
 *         is modelled as a distinct memory reference that can never alias a
 *         real page and distort the cache statistics.
 *
 *      2. The record count. The header line must be the number of records that
 *         follow, because the simulator reads it with fscanf("%d\n", &n) and
 *         then reads exactly n records. This program writes the true count.
 *
 *  OUTPUT
 *      Line 1     record count, decimal
 *      Line 2..N  GPA,hostPFN1..hostPFN5   (hexadecimal, no 0x prefix, no NANs)
 *
 *  EXIT CODES
 *      0  augmented file written
 *      1  usage error, unreadable input, or allocation failure
 *
 *  SEE ALSO
 *      run.sh                    drives this after the module translates
 *      host_gpa_translator.c     produces the raw input
 * =============================================================================
 */

#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>

#define MAX_LINE_LEN 4096
#define MAX_FIELDS 32

typedef struct {
    char *virtual_addr;
    char **pt_pfns;      // Array of page table PFN strings
    int pt_pfn_count;
    char *data_pfn;
    int field_count;
} entry_t;

// Parse a hex string to uint64_t
static uint64_t parse_hex(const char *str) {
    if (!str || strcmp(str, "NAN") == 0) {
        return UINT64_MAX;
    }
    return strtoull(str, NULL, 16);
}

// Compare function for qsort
static int compare_uint64(const void *a, const void *b) {
    uint64_t va = *(uint64_t *)a;
    uint64_t vb = *(uint64_t *)b;
    if (va < vb) return -1;
    if (va > vb) return 1;
    return 0;
}

// Find gaps in sorted PFN list and mark unallocated ranges
static void find_gaps(uint64_t *pfns, int count, uint64_t **unallocated, int *unalloc_count, 
                      uint64_t *total_unalloc_size) {
    *unalloc_count = 0;
    *total_unalloc_size = 0;
    
    if (count < 2) {
        *unallocated = NULL;
        return;
    }
    
    // Start with initial capacity
    int capacity = 1024 * 1024;  // Start with 1M entries
    *unallocated = malloc(capacity * sizeof(uint64_t));
    if (!*unallocated) {
        fprintf(stderr, "Memory allocation failed\n");
        return;
    }
    
    // Find gaps between consecutive PFNs
    for (int i = 0; i < count - 1; i++) {
        if (pfns[i] == UINT64_MAX || pfns[i+1] == UINT64_MAX) {
            continue;  // Skip invalid entries
        }
        
        uint64_t gap_start = pfns[i] + 1;
        uint64_t gap_end = pfns[i+1] - 1;
        
        if (gap_start <= gap_end) {
            // Skip extremely large gaps to avoid memory issues
            // Limit to 100M PFNs per gap
            if (gap_end - gap_start + 1 > 100000000ULL) {
                fprintf(stderr, "Warning: Skipping large gap from %" PRIx64 " to %" PRIx64 "\n", 
                        gap_start, gap_end);
                continue;
            }
            
            // Add all PFNs in the gap
            for (uint64_t pfn = gap_start; pfn <= gap_end; pfn++) {
                // Reallocate if needed
                if (*unalloc_count >= capacity) {
                    // Limit maximum capacity to 1 billion entries (~8GB)
                    if (capacity >= 1000000000) {
                        fprintf(stderr, "Error: Maximum capacity reached. Too many unallocated PFNs.\n");
                        free(*unallocated);
                        *unallocated = NULL;
                        return;
                    }
                    capacity = capacity < 500000000 ? capacity * 2 : capacity + 100000000;
                    uint64_t *new_ptr = realloc(*unallocated, capacity * sizeof(uint64_t));
                    if (!new_ptr) {
                        fprintf(stderr, "Memory reallocation failed\n");
                        free(*unallocated);
                        *unallocated = NULL;
                        return;
                    }
                    *unallocated = new_ptr;
                }
                
                (*unallocated)[*unalloc_count] = pfn;
                (*unalloc_count)++;
                (*total_unalloc_size)++;
            }
        }
    }
    
    // Reallocate to actual size
    if (*unalloc_count > 0) {
        uint64_t *new_ptr = realloc(*unallocated, (*unalloc_count) * sizeof(uint64_t));
        if (new_ptr) {
            *unallocated = new_ptr;
        }
    } else {
        free(*unallocated);
        *unallocated = NULL;
    }
}

int main(int argc, char *argv[]) {
    FILE *in_fp, *out_fp;
    char line[MAX_LINE_LEN];
    entry_t *entries = NULL;
    int entry_count = 0;
    int capacity = 0;
    uint64_t *all_pfns = NULL;
    int all_pfn_count = 0;
    int all_pfn_capacity = 0;
    uint64_t *unallocated_pfns = NULL;
    int unalloc_count = 0;
    uint64_t total_unalloc_size = 0;
    int unalloc_idx = 0;
    
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <input_file> <output_file>\n", argv[0]);
        return 1;
    }
    
    in_fp = fopen(argv[1], "r");
    if (!in_fp) {
        perror("Failed to open input file");
        return 1;
    }
    
    // Read first line (count)
    if (!fgets(line, sizeof(line), in_fp)) {
        fprintf(stderr, "Failed to read count line\n");
        fclose(in_fp);
        return 1;
    }
    
    // Read all entries
    while (fgets(line, sizeof(line), in_fp)) {
        // Remove newline
        line[strcspn(line, "\n")] = 0;
        
        if (strlen(line) == 0) continue;
        
        // Expand capacity if needed
        if (entry_count >= capacity) {
            capacity = capacity ? capacity * 2 : 1024;
            entries = realloc(entries, capacity * sizeof(entry_t));
            if (!entries) {
                fprintf(stderr, "Memory allocation failed\n");
                fclose(in_fp);
                return 1;
            }
        }
        
        entry_t *e = &entries[entry_count];
        memset(e, 0, sizeof(entry_t));
        
        // Parse CSV line
        char *fields[MAX_FIELDS];
        int field_idx = 0;
        char *token = strtok(line, ",");
        
        while (token && field_idx < MAX_FIELDS) {
            fields[field_idx++] = token;
            token = strtok(NULL, ",");
        }
        
        if (field_idx < 2) {
            fprintf(stderr, "Invalid line format: %s\n", line);
            continue;
        }
        
        e->field_count = field_idx;
        e->virtual_addr = strdup(fields[0]);
        
        // All PFNs except the first (virtual address)
        // Last one is data_pfn, rest are pt_pfns
        e->pt_pfn_count = field_idx - 2;  // Exclude virtual_addr and data_pfn
        if (e->pt_pfn_count > 0) {
            e->pt_pfns = malloc(e->pt_pfn_count * sizeof(char *));
            for (int i = 0; i < e->pt_pfn_count; i++) {
                e->pt_pfns[i] = strdup(fields[i + 1]);
            }
        }
        e->data_pfn = strdup(fields[field_idx - 1]);
        
        entry_count++;
        
        // Collect all valid PFNs for gap analysis
        for (int i = 1; i < field_idx; i++) {
            uint64_t pfn = parse_hex(fields[i]);
            if (pfn != UINT64_MAX) {
                if (all_pfn_count >= all_pfn_capacity) {
                    all_pfn_capacity = all_pfn_capacity ? all_pfn_capacity * 2 : 65536;
                    all_pfns = realloc(all_pfns, all_pfn_capacity * sizeof(uint64_t));
                    if (!all_pfns) {
                        fprintf(stderr, "Memory allocation failed\n");
                        fclose(in_fp);
                        return 1;
                    }
                }
                all_pfns[all_pfn_count++] = pfn;
            }
        }
    }
    fclose(in_fp);
    
    printf("Read %d entries\n", entry_count);
    printf("Collected %d valid PFNs\n", all_pfn_count);
    
    // Sort all PFNs
    qsort(all_pfns, all_pfn_count, sizeof(uint64_t), compare_uint64);
    
    // Remove duplicates
    int unique_count = 0;
    for (int i = 0; i < all_pfn_count; i++) {
        if (i == 0 || all_pfns[i] != all_pfns[i-1]) {
            if (i != unique_count) {
                all_pfns[unique_count] = all_pfns[i];
            }
            unique_count++;
        }
    }
    all_pfn_count = unique_count;
    
    printf("Unique PFNs: %d\n", all_pfn_count);
    
    // Find gaps (unallocated PFNs)
    find_gaps(all_pfns, all_pfn_count, &unallocated_pfns, &unalloc_count, &total_unalloc_size);
    
    printf("Unallocated PFN count: %d\n", unalloc_count);
    printf("Total unallocated PFN size: %" PRIu64 "\n", total_unalloc_size);
    
    // Count NAN entries
    int nan_count = 0;
    for (int i = 0; i < entry_count; i++) {
        entry_t *e = &entries[i];
        for (int j = 0; j < e->pt_pfn_count; j++) {
            if (strcmp(e->pt_pfns[j], "NAN") == 0) {
                nan_count++;
            }
        }
        if (strcmp(e->data_pfn, "NAN") == 0) {
            nan_count++;
        }
    }
    
    printf("NAN entries to fill: %d\n", nan_count);
    
    if (nan_count > unalloc_count) {
        fprintf(stderr, "Warning: Need %d unallocated PFNs but only found %d\n", 
                nan_count, unalloc_count);
    }
    
    // Fill NANs with unique unallocated PFNs
    unalloc_idx = 0;
    for (int i = 0; i < entry_count; i++) {
        entry_t *e = &entries[i];

        // Fill PT PFN NANs
        for (int j = 0; j < e->pt_pfn_count; j++) {
            if (strcmp(e->pt_pfns[j], "NAN") == 0) {
                if (unalloc_idx < unalloc_count) {
                    char hex_str[32];
                    snprintf(hex_str, sizeof(hex_str), "%" PRIx64, unallocated_pfns[unalloc_idx]);
                    free(e->pt_pfns[j]);
                    e->pt_pfns[j] = strdup(hex_str);
                    unalloc_idx++;
                }
            }
        }
        
        // Fill data PFN NAN
        if (strcmp(e->data_pfn, "NAN") == 0) {
            if (unalloc_idx < unalloc_count) {
                char hex_str[32];
                snprintf(hex_str, sizeof(hex_str), "%" PRIx64, unallocated_pfns[unalloc_idx]);
                free(e->data_pfn);
                e->data_pfn = strdup(hex_str);
                unalloc_idx++;
            }
        }
    }
    
    // Write augmented file
    out_fp = fopen(argv[2], "w");
    if (!out_fp) {
        perror("Failed to open output file");
        // Cleanup
        for (int i = 0; i < entry_count; i++) {
            entry_t *e = &entries[i];
            free(e->virtual_addr);
            for (int j = 0; j < e->pt_pfn_count; j++) {
                free(e->pt_pfns[j]);
            }
            free(e->pt_pfns);
            free(e->data_pfn);
        }
        free(entries);
        free(all_pfns);
        free(unallocated_pfns);
        return 1;
    }
    
    // Write count (first line)
    fprintf(out_fp, "%d\n", entry_count);
    
    // Write all entries
    for (int i = 0; i < entry_count; i++) {
        entry_t *e = &entries[i];
        fprintf(out_fp, "%s", e->virtual_addr);
        
        for (int j = 0; j < e->pt_pfn_count; j++) {
            fprintf(out_fp, ",%s", e->pt_pfns[j]);
        }
        
        fprintf(out_fp, ",%s\n", e->data_pfn);
    }
    
    fclose(out_fp);
    
    printf("Augmented file written to %s\n", argv[2]);
    printf("Filled %d NAN entries\n", unalloc_idx);
    
    // Cleanup
    for (int i = 0; i < entry_count; i++) {
        entry_t *e = &entries[i];
        free(e->virtual_addr);
        for (int j = 0; j < e->pt_pfn_count; j++) {
            free(e->pt_pfns[j]);
        }
        free(e->pt_pfns);
        free(e->data_pfn);
    }
    free(entries);
    free(all_pfns);
    free(unallocated_pfns);
    
    return 0;
}
