/* A fake monotonic clock/epoll wait lets us observe idle and delayed-commit
 * behavior without sleeping for several minutes. Socket ownership is real. */
#include "/src/net.c"
#include <assert.h>

static volatile uint64_t seconds, wait_advance;
int __real_clock_gettime(clockid_t clock, struct timespec *out);
int __wrap_clock_gettime(clockid_t clock, struct timespec *out) {
    if (clock != CLOCK_MONOTONIC) return __real_clock_gettime(clock, out);
    out->tv_sec = (time_t)seconds; out->tv_nsec = 0; return 0;
}
int __wrap_epoll_wait(int fd, struct epoll_event *events, int count, int timeout) {
    (void)fd; (void)events; (void)count; (void)timeout;
    seconds += wait_advance; wait_advance = 0; return 0;
}
void goose_handle_request(int64_t h,int64_t i,bytes m,bytes p,bytes a,bytes b) {
    (void)h;(void)i;(void)m;(void)p;(void)a;(void)b;abort();
}
static Conn *attach(Server *s, int *peer) {
    int fds[2]; assert(socketpair(AF_UNIX,SOCK_STREAM|SOCK_NONBLOCK,0,fds)==0);
    Conn *c=calloc(1,sizeof(*c)); assert(c);
    c->fd=fds[0];c->activity=seconds;c->all_next=s->all;
    if(s->all)s->all->all_prev=c;
    s->all=c;++s->count;*peer=fds[1];
    struct epoll_event e;memset(&e,0,sizeof(e));
    e.events=EPOLLIN|EPOLLRDHUP;e.data.ptr=c;
    assert(epoll_ctl(s->epoll_fd,EPOLL_CTL_ADD,c->fd,&e)==0);
    c->registered_events=e.events;
    return c;
}
static void live(int peer) {
    uint8_t ch;errno=0;
    ssize_t got=recv(peer,&ch,1,0);
    if(got!=-1||(errno!=EAGAIN&&errno!=EWOULDBLOCK)) {
        fprintf(stderr,"Expected live idle socket at simulated second %llu; recv=%zd errno=%d\n",
                (unsigned long long)seconds,got,errno);abort();
    }
}
int main(void) {
    int64_t net=epoll_net_init((bytes){(const uint8_t *)"127.0.0.1",9},19098);
    assert(net);Server *s=(Server *)(intptr_t)net;
    int peer;attach(s,&peer);
    wait_advance=124;assert(epoll_net_poll(net)==0);live(peer);
    wait_advance=4;assert(epoll_net_poll(net)==0);live(peer);
    wait_advance=1;assert(epoll_net_poll(net)==0);
    uint8_t buf[1024];assert(recv(peer,buf,sizeof(buf),0)==0);close(peer);
    Conn *c=attach(s,&peer);
    assert(response_set(c,200,(const uint8_t *)"x",1)==0);
    s->batch[0]=c;s->batch_count=1;c->active=1;
    seconds=200;epoll_net_flush(net,1);
    assert(recv(peer,buf,sizeof(buf),0)>0);
    wait_advance=124;assert(epoll_net_poll(net)==0);live(peer);
    wait_advance=5;assert(epoll_net_poll(net)==0);
    assert(recv(peer,buf,sizeof(buf),0)==0);close(peer);
    epoll_net_close(net);
    puts("PASS: clock refresh after blocking wait and delayed commit; idle sockets retained through 124/128 seconds and expire after the 125-second minimum plus sweep interval");
    return 0;
}
