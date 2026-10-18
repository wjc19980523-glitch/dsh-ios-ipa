/* Exercise the production block-link/invalidation implementation. Function
 * section GC drops the unrelated CPU dispatcher and its guest dependencies. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef DSH_ASBESTOS_SOURCE_FILE
#define DSH_ASBESTOS_SOURCE_FILE "../ish-arm64/asbestos/asbestos.c"
#endif
#include DSH_ASBESTOS_SOURCE_FILE

/* Only used by disabled production trace arguments during hash allocation. */
int current_pid(void) { return 1; }

#define CHECK(condition, message) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s (%s:%d)\n", message, __FILE__, __LINE__); \
        exit(EXIT_FAILURE); \
    } \
} while (0)

#define MAX_BLOCKS 8
#define FAKE_IP_TAG (1UL << 63)
struct graph {
    struct mmu mmu;
    struct asbestos *asbestos;
    struct fiber_block *blocks[MAX_BLOCKS];
    int target[MAX_BLOCKS][2];
    unsigned count;
};

static void graph_init(struct graph *graph) {
    memset(graph, 0, sizeof(*graph));
    graph->asbestos = asbestos_new(&graph->mmu);
    graph->mmu.asbestos = graph->asbestos;
    for (unsigned b = 0; b < MAX_BLOCKS; b++)
        for (int i = 0; i < 2; i++) graph->target[b][i] = -1;
}

static unsigned add_block(struct graph *graph, addr_t addr, addr_t end) {
    CHECK(graph->count < MAX_BLOCKS, "fixture capacity");
    struct fiber_block *block = calloc(1, sizeof(*block) + 2 * sizeof(unsigned long));
    CHECK(block != NULL, "allocate block");
    block->addr = addr;
    block->end_addr = end;
    block->used = 2;
    list_init(&block->chain);
    list_init(&block->jetsam);
    for (int i = 0; i < 2; i++) {
        /* Same detached representation as production gen_end(). */
        list_init(&block->page[i]);
        list_init(&block->jumps_from[i]);
        list_init(&block->jumps_from_links[i]);
        block->jump_ip[i] = &block->code[i];
        block->old_jump_ip[i] = block->code[i] = FAKE_IP_TAG | (addr + 4);
    }
    unsigned index = graph->count++;
    graph->blocks[index] = block;
    lock(&graph->asbestos->lock);
    fiber_insert(graph->asbestos, block);
    unlock(&graph->asbestos->lock);
    return index;
}

static void set_destination(struct graph *graph, unsigned source, int i, addr_t addr) {
    CHECK(graph->target[source][i] < 0, "set only detached destination");
    struct fiber_block *block = graph->blocks[source];
    block->old_jump_ip[i] = *block->jump_ip[i] = FAKE_IP_TAG | addr;
}

static bool link_blocks(struct graph *graph, unsigned source, unsigned target, int i) {
    lock(&graph->asbestos->lock);
    bool linked = fiber_block_link_if_matching(graph->blocks[source], graph->blocks[target], i);
    unlock(&graph->asbestos->lock);
    if (linked) graph->target[source][i] = (int)target;
    return linked;
}

static bool detached(const struct list *node) {
    return (node->next == NULL && node->prev == NULL) ||
        (node->next == node && node->prev == node);
}

static unsigned check_ring(struct list *head, unsigned limit) {
    if (list_null(head)) return 0;
    CHECK(head->next != NULL && head->prev != NULL, "ring head has both links");
    unsigned count = 0;
    for (struct list *node = head->next; node != head; node = node->next) {
        CHECK(++count <= limit, "ring terminates without duplicate nodes");
        CHECK(node->next != NULL && node->prev != NULL, "ring node has both links");
        CHECK(node->next->prev == node && node->prev->next == node,
            "ring links are reciprocal");
    }
    CHECK(head->next->prev == head && head->prev->next == head,
        "ring head links are reciprocal");
    return count;
}

static bool ring_contains(struct list *head, const struct list *wanted, unsigned limit) {
    (void)check_ring(head, limit);
    if (list_null(head)) return false;
    for (struct list *node = head->next; node != head; node = node->next)
        if (node == wanted) return true;
    return false;
}

static void check_graph(struct graph *graph) {
    unsigned live = 0, jetsam = 0, pages = 0, expected_pages = 0, hash = 0;
    for (unsigned b = 0; b < graph->count; b++) {
        struct fiber_block *block = graph->blocks[b];
        if (block->is_jetsam) {
            jetsam++;
            CHECK(detached(&block->chain), "jetsam block left hash");
            CHECK(detached(&block->page[0]) && detached(&block->page[1]),
                "jetsam block left page hashes");
            CHECK(ring_contains(&graph->asbestos->jetsam, &block->jetsam, graph->count),
                "invalidated block is present in jetsam");
        } else {
            live++;
            expected_pages += 1 + (PAGE(block->addr) != PAGE(block->end_addr));
            CHECK(ring_contains(&graph->asbestos->hash[block->addr % graph->asbestos->hash_size],
                &block->chain, graph->count), "live block is in its hash bucket");
            CHECK(ring_contains(blocks_list(graph->asbestos, PAGE(block->addr), 0),
                &block->page[0], graph->count), "live block start is in its page bucket");
            if (PAGE(block->addr) != PAGE(block->end_addr))
                CHECK(ring_contains(blocks_list(graph->asbestos, PAGE(block->end_addr), 1),
                    &block->page[1], graph->count), "live block end is in its page bucket");
        }
        for (int i = 0; i < 2; i++) {
            unsigned incoming = 0;
            for (unsigned source = 0; source < graph->count; source++)
                if (graph->target[source][i] == (int)b) incoming++;
            CHECK(check_ring(&block->jumps_from[i], graph->count) == incoming,
                "incoming list matches expected edges");
            if (!list_null(&block->jumps_from[i])) {
                for (struct list *node = block->jumps_from[i].next;
                        node != &block->jumps_from[i]; node = node->next) {
                    bool found = false;
                    for (unsigned source = 0; source < graph->count; source++) {
                        if (node == &graph->blocks[source]->jumps_from_links[i]) {
                            CHECK(graph->target[source][i] == (int)b,
                                "incoming node belongs to this target");
                            found = true;
                        }
                    }
                    CHECK(found, "incoming list contains only known block nodes");
                }
            }
            int target = graph->target[b][i];
            if (target < 0) {
                CHECK(detached(&block->jumps_from_links[i]), "unlinked outgoing node is detached");
                /* A disconnected source's own code is no longer published;
                 * production only restores still-published incoming slots. */
                if (!block->is_jetsam)
                    CHECK(*block->jump_ip[i] == block->old_jump_ip[i], "unlinked slot restored fake target");
            } else {
                CHECK(!block->is_jetsam && !graph->blocks[target]->is_jetsam,
                    "no edge references jetsam");
                CHECK(*block->jump_ip[i] == (unsigned long)graph->blocks[target]->code,
                    "linked slot points to target code");
            }
        }
    }
    for (size_t bucket = 0; bucket < graph->asbestos->hash_size; bucket++)
        hash += check_ring(&graph->asbestos->hash[bucket], graph->count);
    for (size_t bucket = 0; bucket < FIBER_PAGE_HASH_SIZE; bucket++)
        for (int i = 0; i < 2; i++)
            pages += check_ring(&graph->asbestos->page_hash[bucket].blocks[i], graph->count);
    CHECK(hash == live && graph->asbestos->num_blocks == live, "hash contains each live block once");
    CHECK(pages == expected_pages, "page hashes contain each live endpoint once");
    CHECK(check_ring(&graph->asbestos->jetsam, graph->count) == jetsam,
        "jetsam contains each invalidated block once");
    CHECK(graph->asbestos->mem_used == live * 2, "block memory accounting matches live graph");
}

static void invalidate(struct graph *graph, page_t page) {
    asbestos_invalidate_range(graph->asbestos, page, page + 1);
    for (unsigned source = 0; source < graph->count; source++) {
        for (int i = 0; i < 2; i++) {
            int target = graph->target[source][i];
            if (graph->blocks[source]->is_jetsam ||
                    (target >= 0 && graph->blocks[target]->is_jetsam))
                graph->target[source][i] = -1;
        }
    }
    check_graph(graph);
}

static void graph_free(struct graph *graph) {
    check_graph(graph);
    /* Production free has no lock operations; retire the fixture's native
     * synchronization objects after the last graph access, before freeing. */
    CHECK(pthread_mutex_destroy(&graph->asbestos->lock.m) == 0, "fixture mutex is unlocked");
    wrlock_destroy(&graph->asbestos->jetsam_lock);
    asbestos_free(graph->asbestos);
    graph->mmu.asbestos = NULL;
}

static void collision_does_not_relink(void) {
    struct graph graph;
    graph_init(&graph);
    unsigned a = add_block(&graph, 0x1000, 0x1004);
    unsigned b = add_block(&graph, 0x2000, 0x2004);
    addr_t collision = (unsigned long)graph.blocks[b]->code & 0xffffffffUL;
    unsigned c = add_block(&graph, collision, collision);
    set_destination(&graph, a, 0, graph.blocks[b]->addr);
    CHECK(link_blocks(&graph, a, b, 0), "first link succeeds");
    CHECK(!link_blocks(&graph, a, c, 0), "already-patched slot must not relink");
    check_graph(&graph);
    invalidate(&graph, PAGE(graph.blocks[b]->addr));
    invalidate(&graph, PAGE(graph.blocks[c]->addr));
    invalidate(&graph, PAGE(graph.blocks[b]->addr));
    graph_free(&graph);
}

static void full_width_guest_target(void) {
    struct graph graph;
    graph_init(&graph);
    unsigned a = add_block(&graph, 0x1000, 0x1004);
    unsigned high = add_block(&graph, 0x123456780ULL, 0x123456784ULL);
    unsigned low = add_block(&graph, 0x23456780, 0x23456784);
    set_destination(&graph, a, 1, graph.blocks[high]->addr);
    CHECK(!link_blocks(&graph, a, low, 1), "different high bits do not match");
    CHECK(link_blocks(&graph, a, high, 1), "full-width guest target links");
    check_graph(&graph);
    invalidate(&graph, PAGE(graph.blocks[high]->addr));
    graph_free(&graph);
}

static void self_and_cross_links(void) {
    struct graph graph;
    graph_init(&graph);
    unsigned a = add_block(&graph, 0x11ff0, 0x12008);
    unsigned b = add_block(&graph, 0x22000, 0x22004);
    unsigned c = add_block(&graph, 0x33000, 0x33004);
    const unsigned targets[3][2] = {{a, b}, {a, c}, {b, c}};
    for (unsigned source = 0; source < 3; source++) {
        for (int i = 0; i < 2; i++) {
            set_destination(&graph, source, i, graph.blocks[targets[source][i]]->addr);
            CHECK(link_blocks(&graph, source, targets[source][i], i), "self/cross edge links");
        }
    }
    check_graph(&graph);
    invalidate(&graph, PAGE(graph.blocks[b]->addr));
    CHECK(!link_blocks(&graph, b, c, 0), "jetsam source cannot link");
    CHECK(!link_blocks(&graph, a, b, 1), "jetsam target cannot link");
    invalidate(&graph, PAGE(graph.blocks[b]->addr));
    invalidate(&graph, PAGE(graph.blocks[a]->end_addr));
    invalidate(&graph, PAGE(graph.blocks[c]->addr));
    CHECK(graph.asbestos->num_blocks == 0, "all blocks invalidated");
    graph_free(&graph);
}

static void colliding_page_buckets(void) {
    struct graph graph;
    graph_init(&graph);
    unsigned a = add_block(&graph, 0x400000, 0x400004);
    unsigned b = add_block(&graph, 0x800000, 0x800004);
    set_destination(&graph, a, 0, graph.blocks[b]->addr);
    set_destination(&graph, b, 1, graph.blocks[a]->addr);
    CHECK(link_blocks(&graph, a, b, 0), "hash-collision edge links");
    CHECK(link_blocks(&graph, b, a, 1), "hash-collision reverse edge links");
    check_graph(&graph);
    invalidate(&graph, PAGE(graph.blocks[a]->addr));
    CHECK(graph.asbestos->num_blocks == 0, "shared page bucket invalidates both blocks");
    invalidate(&graph, PAGE(graph.blocks[b]->addr));
    graph_free(&graph);
}

int main(int argc, char **argv) {
    collision_does_not_relink();
    if (argc > 1 && strcmp(argv[1], "--collision-only") == 0) return 0;
    full_width_guest_target();
    self_and_cross_links();
    colliding_page_buckets();
    puts("ASBESTOS_BLOCK_LINK_TESTS 4/4");
    return 0;
}
