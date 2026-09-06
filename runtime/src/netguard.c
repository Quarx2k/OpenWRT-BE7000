#define _GNU_SOURCE
#include <sys/reboot.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
static long now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec; }
static int expired(long current,long last) { return current-last>=300; }
static int probe(const char *peer) {
    pid_t p=fork(); if(p<0)return 0;
    if(!p){int fd=open("/dev/null",O_RDWR);dup2(fd,1);dup2(fd,2);
        execl("/rescue/bin/busybox","busybox","ping","-I","br-lan","-c","1","-W","1",peer,(char*)0);_exit(127);}
    int status; long start=now();
    while(waitpid(p,&status,WNOHANG)==0){if(now()-start>=3){kill(p,SIGKILL);waitpid(p,&status,0);return 0;}usleep(100000);}
    return WIFEXITED(status)&&WEXITSTATUS(status)==0;
}
int main(int argc,char **argv){
    if(argc==2&&!strcmp(argv[1],"--self-test")){
        if(expired(299,0)||!expired(300,0)||expired(400,200)||!expired(500,200))return 1;
        puts("PASS: 300 seconds continuous outage; success resets deadline");return 0;
    }
    if(argc!=2)return 2;
    setvbuf(stdout,NULL,_IONBF,0);long last=now(),reported=-1;int previous=-1;
    printf("netguard started uptime=%ld peer=%s timeout=300 interface=br-lan\n",last,argv[1]);
    for(;;){int ok=probe(argv[1]);long t=now();if(ok)last=t;
        if(ok!=previous||t-reported>=30){printf("uptime=%ld reachable=%d outage=%ld\n",t,ok,t-last);reported=t;previous=ok;}
        if(expired(t,last)){
            puts("NETGUARD: 300s outage, syncing USB then forced reboot");
            pid_t child=fork();if(child==0){sync();_exit(0);}sleep(2);
            reboot(RB_AUTOBOOT);
            int fd=open("/proc/sysrq-trigger",O_WRONLY);if(fd>=0 && write(fd,"b",1)!=1)perror("sysrq");
            perror("reboot failed");return 1;
        }
        sleep(5);
    }
}
