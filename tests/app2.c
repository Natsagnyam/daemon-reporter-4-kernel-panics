#include <pthread.h>
#include <stdio.h>

static int counter = 0;

static void *thread_fn(void *arg) {
    (void)arg;
    for (int i = 0; i < 100000; ++i) {
        counter++;
    }
    return NULL;
}

int main(void) {
    pthread_t t1, t2;
    pthread_create(&t1, NULL, thread_fn, NULL);
    pthread_create(&t2, NULL, thread_fn, NULL);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);
    printf("counter=%d\n", counter);
    return 0;
}
