#define _GNU_SOURCE
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
int main(int argc,char**argv){
    if(argc!=2)return 2;
    int in=open("/dev/kmsg",O_RDONLY|O_NONBLOCK),out=open(argv[1],O_WRONLY|O_CREAT|O_APPEND|O_DSYNC,0644);
    if(in<0||out<0){perror("open");return 1;}
    char b[16384];struct pollfd p={.fd=in,.events=POLLIN};
    for(;;){ssize_t n=read(in,b,sizeof(b));if(n>0){ssize_t pos=0;while(pos<n){ssize_t w=write(out,b+pos,n-pos);if(w<0){if(errno==EINTR)continue;perror("write");return 1;}pos+=w;}}
        else if(n<0&&(errno==EAGAIN||errno==EINTR))poll(&p,1,1000);
        else if(n<0&&errno==EPIPE)fprintf(stderr,"kmsg overrun\n");
        else {perror("read");return 1;}}
}
