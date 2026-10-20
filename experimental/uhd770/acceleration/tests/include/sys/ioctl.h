#ifndef TEST_SYS_IOCTL_H
#define TEST_SYS_IOCTL_H
#define _IOWR(g,n,t) (0xc0000000UL | ((unsigned long)sizeof(t) << 16) | ((unsigned long)(g) << 8) | (n))
#define _IOW(g,n,t) (0x80000000UL | ((unsigned long)sizeof(t) << 16) | ((unsigned long)(g) << 8) | (n))
#endif
