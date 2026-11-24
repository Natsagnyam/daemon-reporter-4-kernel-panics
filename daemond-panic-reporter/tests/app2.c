/* app2.c: Deliberate Data Race for TSan (-fsanitize=thread) */
#include <pthread.h>
#include <stdio.h>

static int shared_counter = 0;

static void *worker(void *arg) {
    (void)arg;
    for (int i = 0; i < 100000; ++i) {
        shared_counter++; /* Unsynchronized read-modify-write race */
    }
    return NULL;
}

int main(void) {
    pthread_t t1, t2;
    pthread_create(&t1, NULL, worker, NULL);
    pthread_create(&t2, NULL, worker, NULL);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);
    printf("Counter: %d\n", shared_counter);
    return 0;
}
