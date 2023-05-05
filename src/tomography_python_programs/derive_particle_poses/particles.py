from pathlib import Path

import pandas as pd
import starfile
import typer

from ._cli import cli

COMMAND_NAME = 'particles'


@cli.command(name=COMMAND_NAME, no_args_is_help=True)
def combine_particle_annotations(
    tilt_series_star_file: Path = typer.Option(
        ..., help='tilt-series STAR file containing tomogram'
    ),
    annotations_directory: Path = typer.Option(
        ..., help='directory containing annotations in each tomogram'
    ),
    output_directory: Path = typer.Option(
        ..., help="directory into which 'particles.star' will be written."
    )
):
    star = starfile.read(tilt_series_star_file)
    global_table = star['global'].set_index('rlnTomoName')
    annotation_files = annotations_directory.glob('*_particles.star')
    dfs = []
    for file in annotation_files:
        df = starfile.read(file)
        tilt_series_id = ''.join(file.name.split('_')[:-1])
        scale_factor = float(global_table[tilt_series_id]['rlnTomoTomogramBinning'])
        xyz = df[['rlnCoordinateX', 'rlnCoordinateY', 'rlnCoordinateZ']].to_numpy()
        df[['rlnCoordinateX', 'rlnCoordinateY', 'rlnCoordinateZ']] = xyz * scale_factor
        dfs.append(df)
    df = pd.concat(dfs)
    output_file = output_directory / 'particles.star'
    starfile.write({'particles': df}, output_file, overwrite=True)
