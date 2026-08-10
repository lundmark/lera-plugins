import argparse

from . import EXIT_INVALID, EXIT_OK


def build_parser():
    parser = argparse.ArgumentParser(
        description="Legacy parity validation for approved plugins"
    )
    parser.add_subparsers(dest="command")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    return EXIT_OK if args.command else EXIT_INVALID
