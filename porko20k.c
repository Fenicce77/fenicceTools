#include <stdio.h>
#include <stdlib.h>
#define COMMIT_SIZE	20000

main()
{
	char buf[4096];
	int i = 0;

	printf("BEGIN;\n");
	while(fgets(buf, 4095, stdin)) {
		printf("%s", buf);
		i++;
		if (i == COMMIT_SIZE) {
			printf("COMMIT;\n");
			printf("SELECT SLEEP(0.1);\n");
			printf("BEGIN;\n");
			i = 0;
		}
	}
	printf("COMMIT;\n");
	exit(0);
}
