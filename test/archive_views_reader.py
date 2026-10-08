# SPDX-FileCopyrightText: Jukka Aho
# SPDX-License-Identifier: MIT
"""Optional independent qualification of fixtures from archive_views.jl.

Run with Python, h5py, and VTK installed; these are not Episteme dependencies.
"""
import hashlib
from pathlib import Path
import sys
import unittest
import xml.etree.ElementTree as ET

import h5py
from vtkmodules.vtkCommonDataModel import vtkCompositeDataSet
from vtkmodules.vtkCommonExecutionModel import vtkStreamingDemandDrivenPipeline
from vtkmodules.vtkIOXdmf2 import vtkXdmfReader

FIXTURES = Path(sys.argv.pop(1)).resolve()
POINTS = [(0., 0., 0.), (1., 0., 0.), (0., 1., 0.), (1., 1., 0.)]
TRIANGLES = [(5, [0, 1, 2]), (5, [1, 3, 2])]


def reader(name):
    value = vtkXdmfReader()
    value.SetFileName(str(FIXTURES / (name + ".xmf")))
    value.UpdateInformation()
    value.Update()
    return value


def cells(grid):
    return [(grid.GetCellType(i),
             [grid.GetCell(i).GetPointId(j)
              for j in range(grid.GetCell(i).GetNumberOfPoints())])
            for i in range(grid.GetNumberOfCells())]


class ArchiveViewsReader(unittest.TestCase):
    def test_physical_references(self):
        for name in ("surface", "mixed", "levels", "series"):
            root = ET.parse(FIXTURES / (name + ".xmf"))
            for item in root.iter("DataItem"):
                self.assertEqual(item.attrib["Format"], "HDF")
                archive, path = item.text.strip().split(":", 1)
                with h5py.File(FIXTURES / archive, "r") as file:
                    dataset = file[path]
                    self.assertEqual(dataset.shape,
                                     tuple(map(int, item.attrib["Dimensions"].split())))
                    self.assertEqual(dataset.dtype.itemsize, int(item.attrib["Precision"]))
                    self.assertIn(dataset.dtype.kind, "fiu")
        with h5py.File(FIXTURES / "numeric & data.ah5", "r") as file:
            self.assertEqual(file["/data/coordinates"][:].tolist(), [list(p) for p in POINTS])
            self.assertEqual(file["/data/triangles"][:].tolist(), [[0, 1, 2], [1, 3, 2]])

    def test_identity_metadata(self):
        root = ET.parse(FIXTURES / "surface.xmf")
        information = {i.attrib["Name"]: i.attrib["Value"]
                       for i in root.iter("Information")}
        self.assertEqual(information["ArchiveId"], "fixed-view-archive")
        self.assertEqual(information["ObjectId:/data/coordinates"], "fixture-object")
        self.assertEqual(information["RevisionId:/data/coordinates"], "fixture-revision")
        self.assertIn("DatasetContentId:/data/coordinates", information)
        self.assertIn("ProjectionContentId", information)
        self.assertNotIn("nonvisual scientific metadata",
                         (FIXTURES / "surface.xmf").read_text())

    def test_surface_fields_and_subset(self):
        output = reader("surface").GetOutputDataObject(0)
        self.assertEqual(output.GetNumberOfBlocks(), 2)
        grid = output.GetBlock(0)
        self.assertEqual([grid.GetPoint(i) for i in range(4)], POINTS)
        self.assertEqual(cells(grid), TRIANGLES)
        data = grid.GetPointData()
        self.assertEqual([data.GetArray("point values").GetTuple1(i) for i in range(4)],
                         [2., 3., 5., 7.])
        self.assertEqual([data.GetArray("velocity").GetTuple(i) for i in range(4)],
                         [(1., 0., 2.), (2., 1., 2.), (3., 0., 2.), (4., 1., 2.)])
        self.assertEqual([grid.GetCellData().GetArray("cell values").GetTuple1(i)
                          for i in range(2)], [11., 13.])
        subset = output.GetBlock(1)
        self.assertEqual(output.GetMetaData(1).Get(vtkCompositeDataSet.NAME()), "chosen cells")
        self.assertEqual(subset.GetNumberOfCells(), 1)
        self.assertEqual({subset.GetPoint(i) for i in range(3)}, set(POINTS[1:]))

    def test_mixed_topology(self):
        grid = reader("mixed").GetOutputDataObject(0)
        self.assertEqual([grid.GetPoint(i) for i in range(4)], POINTS)
        self.assertEqual(cells(grid), [(5, [0, 1, 2]), (9, [0, 1, 3, 2])])

    def test_nested_levels(self):
        output = reader("levels").GetOutputDataObject(0)
        self.assertEqual(output.GetNumberOfBlocks(), 2)
        self.assertEqual([output.GetMetaData(i).Get(vtkCompositeDataSet.NAME())
                          for i in range(2)], ["coarse", "fine"])
        self.assertEqual(cells(output.GetBlock(0).GetBlock(0).GetBlock(0)), TRIANGLES)
        self.assertEqual(cells(output.GetBlock(1).GetBlock(0)), [(9, [0, 1, 3, 2])])

    def test_temporal_values(self):
        value = reader("series")
        key = vtkStreamingDemandDrivenPipeline.TIME_STEPS()
        self.assertEqual(value.GetOutputInformation(0).Get(key), (0., 1.))
        for time, expected in ((0., [2., 3., 5., 7.]), (1., [4., 6., 10., 14.])):
            value.UpdateTimeStep(time)
            grid = value.GetOutputDataObject(0)
            self.assertEqual(cells(grid), TRIANGLES)
            field = grid.GetPointData().GetArray("point values")
            self.assertEqual([field.GetTuple1(i) for i in range(4)], expected)

    def test_reader_does_not_change_archive(self):
        path = FIXTURES / "numeric & data.ah5"
        before = hashlib.sha256(path.read_bytes()).digest()
        for name in ("surface", "mixed", "levels", "series"):
            reader(name)
        self.assertEqual(hashlib.sha256(path.read_bytes()).digest(), before)


if __name__ == "__main__":
    unittest.main()
