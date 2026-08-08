#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DEFAULT_BATCH_SIZE 2000

static void print_usage(const char *program_name)
{
	printf("Usage: %s [-b SIZE | --batch-size SIZE]\n", program_name);
	printf("Wrap SQL input lines in transactions of SIZE statements (default: %d).\n", DEFAULT_BATCH_SIZE);
	printf("Examples:\n  %s -b 500 < queries.sql > transactions.sql\n", program_name);
	printf("  %s --batch-size 2000 < queries.sql > transactions.sql\n", program_name);
}

static int parse_batch_size(const char *value, int *batch_size)
{
	char *end = NULL;
	long parsed;

	errno = 0;
	parsed = strtol(value, &end, 10);
	if (errno != 0 || end == value || *end != '\0' || parsed <= 0 || parsed > INT_MAX) {
		fprintf(stderr, "Error: batch size must be a positive integer.\n");
		return -1;
	}
	*batch_size = (int)parsed;
	return 0;
}

static int parse_arguments(int argc, char *argv[], int *batch_size)
{
	if (argc == 1)
		return 0;
	if (argc == 2 && (!strcmp(argv[1], "-h") || !strcmp(argv[1], "--help"))) {
		print_usage(argv[0]);
		return 1;
	}
	if (argc == 3 && (!strcmp(argv[1], "-b") || !strcmp(argv[1], "--batch-size")))
		return parse_batch_size(argv[2], batch_size);
	fprintf(stderr, "Error: use -h or --help for usage.\n");
	return -1;
}

int main(int argc, char *argv[])
{
	char buf[4096];
	int batch_size = DEFAULT_BATCH_SIZE;
	int count = 0;
	int argument_status = parse_arguments(argc, argv, &batch_size);

	if (argument_status > 0)
		return EXIT_SUCCESS;
	if (argument_status < 0)
		return EXIT_FAILURE;

	printf("START TRANSACTION;\n");
	while (fgets(buf, sizeof(buf), stdin)) {
		printf("%s", buf);
		count++;
		if (count == batch_size) {
			printf("COMMIT;\nSELECT SLEEP(0.3);\nSTART TRANSACTION;\n");
			count = 0;
		}
	}
	printf("COMMIT;\n");
	return EXIT_SUCCESS;
}
